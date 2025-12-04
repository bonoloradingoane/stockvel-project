import json
import os
import time
import google.generativeai as genai
from web3 import Web3
from dotenv import load_dotenv
import socketio
from sqlalchemy import create_engine, Column, Integer, String, Float, Boolean
from sqlalchemy.orm import sessionmaker
from sqlalchemy.orm import declarative_base

# setup
load_dotenv()
print("Listener Agent starting up...")

# configurations
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
CHAIN_URL = os.getenv("CHAIN_URL")
SOCKETIO_SERVER_URL = 'http://127.0.0.1:5000'
AGENT_PRIVATE_KEY = os.getenv("AGENT_PRIVATE_KEY")

# web3 setup
w3 = Web3(Web3.HTTPProvider(CHAIN_URL))
try:
    with open('Stokvel.json', 'r') as f:
        contract_abi = json.load(f)['abi']
    stokvel_contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=contract_abi)
    print("Successfully connected to Ronin blockchain and contract.")
except Exception as e:
    print(f"FATAL: Error setting up Web3. Is Stokvel.json present? Error: {e}")
    exit()

# agent wallet setup
if not AGENT_PRIVATE_KEY:
    print(
        "FATAL: AGENT_PRIVATE_KEY not found in .env. The agent cannot send transactions."
    )
    exit()
try:
    agent_account = w3.eth.account.from_key(AGENT_PRIVATE_KEY)
    w3.eth.default_account = agent_account.address
    print(f"Agent Wallet Initialized. Address: {agent_account.address}")
except Exception as e:
    print(f"FATAL: Invalid AGENT_PRIVATE_KEY. Error: {e}")
    exit()


# gemini ai setup
if GEMINI_API_KEY:
    genai.configure(api_key=GEMINI_API_KEY)
    model = genai.GenerativeModel('gemini-2.5-pro')
    print("Gemini AI Model Initialized.")
else:
    model = None
    print(
        "Warning: GEMINI_API_KEY not found. AI features for notifications will be disabled."
    )

# database Setup to read rules
Base = declarative_base()


class AutoFundRule(Base):
    __tablename__ = 'auto_fund_rule'
    id = Column(Integer, primary_key=True)
    user_address = Column(String(42), unique=True, nullable=False)
    max_fund_amount = Column(Float, nullable=False)
    min_savings_balance = Column(Float, nullable=False)
    is_active = Column(Boolean, default=True)


try:
    engine = create_engine('sqlite:///stokvel.db')
    Session = sessionmaker(bind=engine)
    db_session = Session()
    print("Successfully connected to the agent rules database.")
except Exception as e:
    print(
        f"FATAL: Could not connect to database. Is app.py running/DB created? Error: {e}"
    )
    exit()


# socket client setup
sio = socketio.Client()


@sio.event
def connect():
    print("Successfully connected to the Flask-SocketIO server.")


@sio.event
def connect_error(data):
    print(
        f"Connection to Flask-SocketIO server failed! Is the Flask server (app.py) running? Data: {data}"
    )


@sio.event
def disconnect():
    print("Disconnected from the Flask-SocketIO server.")


def listen_for_events():
    """
    The main loop for the listener agent. It polls for new events and runs periodic checks.
    """
    application_filter = stokvel_contract.events.ApplicationSubmitted.create_filter(
        from_block='latest'
    )
    loan_funded_filter = stokvel_contract.events.LoanFunded.create_filter(
        from_block='latest'
    )
    loan_disbursed_filter = stokvel_contract.events.LoanDisbursed.create_filter(
        from_block='latest'
    )
    # filter for new loan requests to trigger the agent
    loan_requested_filter = stokvel_contract.events.LoanRequested.create_filter(
        from_block='latest'
    )

    last_default_check = time.time()

    print("Starting to listen for real-time blockchain events and periodic checks...")
    while True:
        try:
            # handle new loan requests
            for event in loan_requested_filter.get_new_entries():
                print(
                    f"AGENT: Detected new Loan Request #{event.args.loanId}. Checking rules..."
                )
                handle_auto_fund(event)

            for event in application_filter.get_new_entries():
                print(f"EVENT: New Application from {event.args.applicant}")
                handle_new_application(event)

            for event in loan_funded_filter.get_new_entries():
                print(f"EVENT: Loan Funded by {event.args.lender}")
                handle_loan_funded(event)

            for event in loan_disbursed_filter.get_new_entries():
                print(f"EVENT: Loan Disbursed to {event.args.borrower}")
                handle_loan_disbursed(event)

            if time.time() - last_default_check > 300:  # 5 minutes
                print(
                    "AGENT: Performing periodic check for potentially defaulted loans..."
                )
                check_for_potential_defaults()
                last_default_check = time.time()

            time.sleep(15)

        except Exception as e:
            print(f"An error occurred in the event loop: {e}")
            time.sleep(15)


# auto-Fund handler
def handle_auto_fund(event):
    loan_id = event.args.loanId
    borrower_address = event.args.borrower

    # get all active auto-funding rules from the database
    active_rules = db_session.query(AutoFundRule).filter_by(is_active=True).all()
    if not active_rules:
        print("AGENT: No active auto-fund rules found.")
        return

    print(
        f"AGENT: Found {len(active_rules)} active rule(s). Analyzing loan #{loan_id}..."
    )

    # get loan details from the contract
    loan_data = stokvel_contract.functions.getLoan(loan_id).call()
    amount_requested_wei = loan_data[1]
    amount_funded_wei = loan_data[2]
    amount_needed_wei = amount_requested_wei - amount_funded_wei

    if amount_needed_wei <= 0:
        print(f"AGENT: Loan #{loan_id} is already fully funded. Skipping.")
        return

    for rule in active_rules:
        try:
            potential_lender_address = rule.user_address

            # user cannot auto-fund their own loan.
            if potential_lender_address.lower() == borrower_address.lower():
                print(
                    f"AGENT: Skipper rule for {potential_lender_address[:8]}... (cannot fund own loan)."
                )
                continue

            # on-chain check to get the potential lender's current financial status
            lender_data = stokvel_contract.functions.getMember(
                potential_lender_address
            ).call()
            available_savings_wei = lender_data[5]

            # convert all values from Wei to Ether for comparison
            available_savings_ether = float(w3.from_wei(available_savings_wei, 'ether'))
            amount_needed_ether = float(w3.from_wei(amount_needed_wei, 'ether'))

            if available_savings_ether >= rule.min_savings_balance:
                # determine the amount to fund: the lesser of their max rule, or what's needed for the loan
                fund_amount_ether = min(rule.max_fund_amount, amount_needed_ether)

                if (
                    fund_amount_ether > 0
                    and available_savings_ether >= fund_amount_ether
                ):
                    print(
                        f"AGENT: MATCH! User {potential_lender_address[:8]}... meets criteria."
                    )
                    print(f"  - Available Savings: {available_savings_ether:.4f} RON")
                    print(f"  - Min Balance Rule: {rule.min_savings_balance:.4f} RON")
                    print(f"  - Max Fund Rule: {rule.max_fund_amount:.4f} RON")
                    print(f"  - Amount to Fund: {fund_amount_ether:.4f} RON")

                    # execute the transaction
                    fund_amount_wei = w3.to_wei(fund_amount_ether, 'ether')

                    nonce = w3.eth.get_transaction_count(agent_account.address)
                    tx_data = {
                        'from': agent_account.address,
                        'nonce': nonce,
                        'gasPrice': w3.eth.gas_price,
                    }

                    # build and sign the transaction
                    fund_tx = stokvel_contract.functions.fundLoan(
                        loan_id, fund_amount_wei
                    ).build_transaction(tx_data)
                    signed_tx = w3.eth.account.sign_transaction(
                        fund_tx, private_key=AGENT_PRIVATE_KEY
                    )

                    # send the transaction and wait for receipt
                    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
                    print(
                        f"AGENT: Auto-funding transaction sent! Hash: {tx_hash.hex()}. Waiting for receipt..."
                    )
                    tx_receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

                    if tx_receipt.status == 1:
                        print(
                            f"AGENT: SUCCESS! Auto-fund for Loan #{loan_id} confirmed."
                        )
                        sio.emit(
                            'new_notification',
                            {
                                'message': f"Your Auto-Fund Agent just invested {fund_amount_ether:.4f} RON in Loan #{loan_id} for you!",
                                'type': 'success',
                            },
                        )
                        # update amount needed for the next rule in the loop
                        amount_needed_wei -= fund_amount_wei
                        if amount_needed_wei <= 0:
                            print(
                                f"AGENT: Loan #{loan_id} is now fully funded. Halting agent for this loan."
                            )
                            break
                    else:
                        print(
                            f"AGENT: FAILED! Auto-fund tx for Loan #{loan_id} reverted."
                        )
                        sio.emit(
                            'new_notification',
                            {
                                'message': f"Agent Alert: Your auto-fund for loan #{loan_id} failed on-chain.",
                                'type': 'alert',
                            },
                        )
                else:
                    print(
                        f"AGENT: User {potential_lender_address[:8]}... can't cover fund amount."
                    )
            else:
                print(
                    f"AGENT: User {potential_lender_address[:8]}... savings below minimum threshold."
                )

        except Exception as e:
            print(f"AGENT: Error processing rule for {rule.user_address}. Error: {e}")
            continue


def check_for_potential_defaults():
    try:
        total_loans = stokvel_contract.functions.getTotalLoans().call()
        for i in range(total_loans):
            loan_data = stokvel_contract.functions.getLoan(i).call()
            is_active, is_defaulted, next_idx = loan_data[5], loan_data[6], loan_data[7]
            if is_active and not is_defaulted and next_idx < 12:
                installment_data = stokvel_contract.functions.getInstallment(
                    i, next_idx
                ).call()
                due_date_timestamp = installment_data[0]
                if time.time() > (due_date_timestamp + 5616000):
                    print(
                        f"ALERT: Loan #{i} is potentially in default. Notifying members."
                    )
                    message = f"Agent Alert: Loan #{i} appears to be severely overdue. A member should investigate and consider triggering a default check."
                    sio.emit('new_notification', {'message': message, 'type': 'alert'})
    except Exception as e:
        print(f"Error during default check: {e}")


def handle_new_application(event):
    try:
        if not model:
            raise Exception("Gemini model not available.")
        prompt = """
        You are an AI agent for a Stokvel savings club. Your task is to generate the EXACT text for a toast notification.
        A new member has just applied to join the club.
        Generate a single, short, exciting, and friendly sentence (under 15 words) to notify all existing members and encourage them to vote.
        Do NOT provide options. Do NOT use markdown. Provide ONLY the single sentence of text for the notification.
        """
        response = model.generate_content(prompt)
        message = response.text
    except Exception as e:
        print(f"Gemini call failed, using fallback message. Error: {e}")
        message = (
            "A new member has applied! Check the Governance tab to cast your vote."
        )
    sio.emit('new_notification', {'message': message})
    print(f"Emitted notification: '{message}'")


def handle_loan_funded(event):
    amount_funded = w3.from_wei(event.args.amount, 'ether')
    loan_id = event.args.loanId
    message = f"Loan #{loan_id} just received {amount_funded:.4f} RON in funding!"
    sio.emit('new_notification', {'message': message, 'type': 'info'})
    print(f"Emitted notification: '{message}'")


def handle_loan_disbursed(event):
    amount = w3.from_wei(event.args.amount, 'ether')
    loan_id = event.args.loanId
    message = f"Success! Loan #{loan_id} is now fully funded and {amount:.4f} RON has been disbursed."
    sio.emit('new_notification', {'message': message, 'type': 'success'})
    print(f"Emitted notification: '{message}'")


if __name__ == '__main__':
    try:
        sio.connect(SOCKETIO_SERVER_URL, wait_timeout=10)
        listen_for_events()
    except socketio.exceptions.ConnectionError as e:
        print(
            f"Could not connect to the server at {SOCKETIO_SERVER_URL}. Please ensure the Flask app (app.py) is running first. Error: {e}"
        )
    except Exception as e:
        print(f"A critical error occurred: {e}")
    finally:
        if sio.connected:
            sio.disconnect()