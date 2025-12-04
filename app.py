import json
import os
import google.generativeai as genai
from flask import Flask, jsonify, render_template, request
from flask_sqlalchemy import SQLAlchemy
from flask_socketio import SocketIO
from web3 import Web3
from datetime import datetime
from dotenv import load_dotenv

# load config
load_dotenv()
app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv("SECRET_KEY", "a_super_secret_key_for_dev_only")
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///stokvel.db'
db = SQLAlchemy(app)
socketio = SocketIO(app)

CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS", "YOUR_DEPLOYED_CONTRACT_ADDRESS")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
CHAIN_URL = os.getenv("CHAIN_URL")


# web3 Setup
w3 = Web3(Web3.HTTPProvider(CHAIN_URL))
contract_abi = None
try:
    with open('Stokvel.json', 'r') as f:
        contract_abi = json.load(f)['abi']
except FileNotFoundError:
    print(
        "Error: Stokvel.json not found. Please place the contract ABI in the root folder."
    )
    exit()
except json.JSONDecodeError:
    print(
        "Error: Could not decode Stokvel.json. Please ensure it is a valid JSON file."
    )
    exit()

stokvel_contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=contract_abi)

# gemini aI setup
if GEMINI_API_KEY:
    genai.configure(api_key=GEMINI_API_KEY)
    model = genai.GenerativeModel('gemini-2.5-pro')
    print("Gemini AI Model Initialized.")
else:
    model = None
    print(
        "Warning: GEMINI_API_KEY not found in .env file. AI features will be disabled."
    )


# db model for agent rules
class AutoFundRule(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    user_address = db.Column(db.String(42), unique=True, nullable=False)
    max_fund_amount = db.Column(db.Float, nullable=False)
    min_savings_balance = db.Column(db.Float, nullable=False)
    is_active = db.Column(db.Boolean, default=True)


class AutoRepayRule(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    user_address = db.Column(db.String(42), unique=True, nullable=False)
    is_active = db.Column(db.Boolean, default=True)


# api routes
@app.route('/api/club-info')
def get_club_info():
    try:
        total_members = stokvel_contract.functions.totalMembers().call()
        creator_address = stokvel_contract.functions.creator().call()
        return jsonify(
            {
                'success': True,
                'totalMembers': total_members,
                'creatorAddress': creator_address,
            }
        )
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/member-info/<address>')
def get_member_info(address):
    try:
        checksum_address = w3.to_checksum_address(address)

        if not w3.is_address(checksum_address):
            return jsonify({'success': False, 'error': 'Invalid address provided'}), 400

        member_data = stokvel_contract.functions.getMember(checksum_address).call()
        return jsonify(
            {
                'success': True,
                'data': {
                    'isActive': member_data[0],
                    'totalSavings': str(w3.from_wei(member_data[2], 'ether')),
                    'amountLentOut': str(w3.from_wei(member_data[3], 'ether')),
                    'amountLockedCollateral': str(w3.from_wei(member_data[4], 'ether')),
                    'availableSavings': str(w3.from_wei(member_data[5], 'ether')),
                },
            }
        )
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/contract-info')
def get_contract_info():
    return jsonify({'address': CONTRACT_ADDRESS, 'abi': contract_abi})


@app.route('/api/open-loans')
def get_open_loans():
    try:
        total_loans = stokvel_contract.functions.getTotalLoans().call()
        open_loans = []
        for i in range(total_loans):
            loan_data = stokvel_contract.functions.getLoan(i).call()
            if not loan_data[5] and not loan_data[6] and loan_data[2] < loan_data[1]:
                open_loans.append(
                    {
                        'loanId': i,
                        'borrower': loan_data[0],
                        'amountRequested': str(w3.from_wei(loan_data[1], 'ether')),
                        'amountFunded': str(w3.from_wei(loan_data[2], 'ether')),
                    }
                )
        return jsonify({'success': True, 'data': open_loans})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/applicant-status/<applicant_address>/<voter_address>')
def get_applicant_status(applicant_address, voter_address):
    """Gets the detailed voting status and checks if the voter has already voted."""
    try:
        # checksum both addresses
        checksum_applicant = w3.to_checksum_address(applicant_address)
        checksum_voter = w3.to_checksum_address(voter_address)

        if not w3.is_address(checksum_applicant) or not w3.is_address(checksum_voter):
            return jsonify({'success': False, 'error': 'Invalid address provided'}), 400

        status_data = stokvel_contract.functions.getApplicantVotingStatus(
            checksum_applicant
        ).call()

        is_approved = stokvel_contract.functions.isApplicantApproved(
            checksum_applicant
        ).call()

        member_has_voted = stokvel_contract.functions.hasMemberVoted(
            checksum_voter, checksum_applicant
        ).call()

        response_data = {
            'positiveVotes': status_data[0],
            'negativeVotes': status_data[1],
            'creatorVoted': status_data[2],
            'creatorVotePositive': status_data[3],
            'totalOtherMembers': status_data[4],
            'requiredVotes': status_data[5],
            'decisionMade': status_data[6],
            'isApproved': is_approved,
            'memberHasVoted': member_has_voted,
        }
        return jsonify({'success': True, 'data': response_data})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/my-loans/<address>')
def get_my_loans(address):
    """Fetches all loans borrowed by a specific address."""
    try:
        checksum_address = w3.to_checksum_address(address)
        if not w3.is_address(checksum_address):
            return jsonify({'success': False, 'error': 'Invalid address provided'}), 400

        total_loans = stokvel_contract.functions.getTotalLoans().call()
        my_loans = []
        for i in range(total_loans):
            # we only need to call getLoan once per loan
            loan_data = stokvel_contract.functions.getLoan(i).call()

            # check if the current user is the borrower of this loan
            if loan_data[0].lower() == checksum_address.lower():

                is_active = loan_data[5]
                next_installment_index = loan_data[7]
                is_paid_off = next_installment_index >= 12

                next_payment_due = 0
                next_payment_amount = 0

                # If the loan is active on-chain and not yet paid off,
                # then we  fetch its next installment details.
                if is_active and not is_paid_off:
                    installment_data = stokvel_contract.functions.getInstallment(
                        i, next_installment_index
                    ).call()
                    next_payment_due = installment_data[0]
                    next_payment_amount = installment_data[1]

                loan_details = {
                    'loanId': i,
                    'amountRequested': str(w3.from_wei(loan_data[1], 'ether')),
                    'isActive': is_active,
                    'isDefaulted': loan_data[6],
                    'isPaidOff': is_paid_off,
                    'nextInstallmentIndex': next_installment_index,
                    'nextPaymentDue': next_payment_due,
                    'nextPaymentAmount': str(w3.from_wei(next_payment_amount, 'ether')),
                }
                my_loans.append(loan_details)

        return jsonify({'success': True, 'data': my_loans})
    except Exception as e:
        print(f"Error in /api/my-loans: {e}")
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/loan-details/<int:loan_id>')
def get_loan_details(loan_id):
    """Fetches comprehensive details for a single loan, including all installments AND lenders."""
    try:
        loan_data = stokvel_contract.functions.getLoan(loan_id).call()

        installments = []
        for i in range(12):
            inst_data = stokvel_contract.functions.getInstallment(loan_id, i).call()
            installments.append(
                {
                    'index': i,
                    'dueDateFormatted': datetime.fromtimestamp(inst_data[0]).strftime(
                        '%Y-%m-%d %H:%M'
                    ),
                    'amountDue': str(w3.from_wei(inst_data[1], 'ether')),
                    'lateFeesAccrued': str(w3.from_wei(inst_data[2], 'ether')),
                    'isPaid': inst_data[3],
                }
            )

        lenders = []
        lender_addresses = stokvel_contract.functions.getLenderList(loan_id).call()
        for address in lender_addresses:
            amount_lent = stokvel_contract.functions.getLenderAmount(
                loan_id, address
            ).call()
            lenders.append(
                {'address': address, 'amount': str(w3.from_wei(amount_lent, 'ether'))}
            )

        response_data = {
            'loanId': loan_id,
            'borrower': loan_data[0],
            'amountRequested': str(w3.from_wei(loan_data[1], 'ether')),
            'amountFunded': str(w3.from_wei(loan_data[2], 'ether')),
            'collateralLocked': str(w3.from_wei(loan_data[3], 'ether')),
            'totalInterest': str(w3.from_wei(loan_data[4], 'ether')),
            'isActive': loan_data[5],
            'isDefaulted': loan_data[6],
            'nextInstallmentIndex': loan_data[7],
            'createdAt': datetime.fromtimestamp(loan_data[8]).strftime(
                '%Y-%m-%d %H:%M'
            ),
            'installments': installments,
            'lenders': lenders,
        }
        return jsonify({'success': True, 'data': response_data})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/gemini-insight', methods=['POST'])
def get_gemini_insight():
    if not model:
        return jsonify({'success': False, 'error': 'Gemini AI is not configured.'})
    user_data = request.json
    if not user_data:
        return jsonify({'success': False, 'error': 'No data provided.'})
    try:
        prompt = f"""You are a friendly financial assistant for a 'Stokvel' savings club. Analyze the user's data and provide a brief, helpful summary in Markdown. Do not give financial advice.
        User's Data: {json.dumps(user_data)}"""
        response = model.generate_content(prompt)
        return jsonify({'success': True, 'insight': response.text})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/agent/autofund', methods=['POST', 'GET'])
def manage_autofund_agent():
    if request.method == 'GET':
        address = request.args.get('address')
        if not address:
            return jsonify({'success': False, 'error': 'Address required.'}), 400
        rule = AutoFundRule.query.filter_by(user_address=address).first()
        if rule:
            return jsonify(
                {
                    'success': True,
                    'data': {
                        'max_fund_amount': rule.max_fund_amount,
                        'min_savings_balance': rule.min_savings_balance,
                        'is_active': rule.is_active,
                    },
                }
            )
        return jsonify({'success': False, 'error': 'No rule found'})

    data = request.json
    address = data.get('address')
    if not address:
        return jsonify({'success': False, 'error': 'Address required.'}), 400
    rule = AutoFundRule.query.filter_by(user_address=address).first()
    if not rule:
        rule = AutoFundRule(user_address=address)

    # get the raw values from the request payload
    max_fund_value = data.get('max_fund_amount')
    min_savings_value = data.get('min_savings_balance')

    # convert to float, defaulting to 0.0 if the value is an empty string or None
    rule.max_fund_amount = float(max_fund_value) if max_fund_value else 0.0
    rule.min_savings_balance = float(min_savings_value) if min_savings_value else 0.0

    rule.is_active = bool(data.get('is_active', False))

    db.session.add(rule)
    db.session.commit()
    socketio.emit('new_notification', {'message': 'Auto-Fund Agent settings saved!'})
    return jsonify({'success': True, 'message': 'Rule saved.'})


@app.route('/')
def home():
    return render_template('index.html')


if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    socketio.run(app, debug=True, allow_unsafe_werkzeug=True)