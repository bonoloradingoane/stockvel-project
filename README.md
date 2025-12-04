# Stokvel DApp on the Ronin Blockchain

A fully-featured, decentralized application for running a digital savings and loan club (a "Stokvel") on the Ronin network, complete with an AI assistant and an automated funding agent for the UJ Blockchain BACISS program.

This project provides a complete Web3 solution, including a Python backend with a real-time event listener and a vanilla JavaScript frontend, demonstrating how to build complex, interactive, and automated decentralized applications.

---

## Features

- **Membership Management**: Users can apply to join the club, and existing members can vote on applicants.
- **Savings & Withdrawals**: Members can deposit RON into their personal savings pool and withdraw available funds.
- **Decentralized Lending**:
  - Members can request loans, putting up a portion of their savings as collateral.
  - Other members can browse and fund open loan requests.
  - Borrowers can make monthly repayments.
- **Automated Default Handling**: An on-chain function allows any member to check for and trigger a default on severely overdue loans.
- **Real-Time Notifications**: A Python-based listener agent watches the blockchain for events and pushes real-time toast notifications to all connected users via WebSockets.
- **AI Financial Assistant**: Integrates with Google's Gemini AI to provide members with a personalized, natural-language summary of their financial position within the Stokvel.
- ** Fully Functional Auto-Fund Agent**: Members can define rules (e.g., _"keep 2 RON in savings, but use the rest to fund loans up to 0.5 RON each"_). A backend agent will automatically execute funding transactions on their behalf.

---

## Tech Stack

### Blockchain

- **Solidity** for the smart contract, deployed on **Ronin (Saigon Testnet)**

### Backend (Python)

- **Web Framework**: Flask & Flask-SocketIO
- **Blockchain Interaction**: Web3.py
- **Database**: SQLite with SQLAlchemy ORM
- **AI Integration**: `google-generativeai`

### Frontend

- **Vanilla HTML, CSS, and JavaScript**
  - **Blockchain Interaction**: Ethers.js (v5)
  - **Real-Time Communication**: Socket.IO Client

### Infrastructure

- **RPC Node**: Chainstack for a reliable Ronin (Saigon) endpoint
- **Wallet**: Ronin Wallet browser extension

---

## Prerequisites

Before you begin, ensure you have the following installed:

- Python (3.8+)
- A code editor (e.g., VS Code)
- The **Ronin Wallet** browser extension
- A deployed version of the `Stokvel.sol` smart contract on the **Ronin Saigon Testnet**

---

## Getting Started: Setup and Installation

## Step 1: Set Up a Ronin RPC with Chainstack

For a stable and high-performance connection, a dedicated RPC node is recommended over public endpoints.

1. **Sign Up**: Create a free account on [Chainstack.com](https://chainstack.com).
2. **Create a Project**: In your dashboard, create a new project.
3. **Join Network**: Click **"Join a network"** → select **Ronin**.
4. **Deploy a Node**:
   - Under **"Network"**, select **Saigon (Testnet)**.
5. **Get Endpoint URL**: Click on your node → copy the **HTTPS endpoint**  
   (e.g., `https://ronin-saigon.core.chainstack.com/your-unique-hash`).

---

## Step 2: Configure Your Environment

1. In the project root, create a `.env` file.
2. Use the template below and fill in your details.

```env
# .env file

# your Stokvel smart contract's address on the Saigon Testnet
CONTRACT_ADDRESS="0x..."

# HTTPS RPC endpoint URL from Chainstack
CHAIN_URL="https://ronin-saigon.core.chainstack.com/your-unique-hash"

# aPI key for Google Gemini
GEMINI_API_KEY="AIza..."

# A random secret key for Flask sessions
SECRET_KEY="a_very_secret_string_for_development"

# the private key for the agent/bot wallet
# This wallet MUST be funded with RON for gas fees
# ALWAYS prefix with 0x
AGENT_PRIVATE_KEY="0x..."
```

### Variable Explanation

| Variable            | Description                                                                                                                            |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `CONTRACT_ADDRESS`  | Address of your deployed `Stokvel.sol` contract                                                                                        |
| `CHAIN_URL`         | Reliable HTTPS endpoint from Chainstack                                                                                                |
| `GEMINI_API_KEY`    | Google AI Studio API key for AI assistant                                                                                              |
| `SECRET_KEY`        | Secret key for Flask session management                                                                                                |
| `AGENT_PRIVATE_KEY` | _(Crucial)_ Private key of a dedicated Ronin wallet used by `listener.py` to send auto-funding transactions. **Must have RON for gas** |

---

## Step 3: Install Backend Dependencies

```bash
# Create a virtual environment
python -m venv venv

# Activate it
# On Windows:
venv\Scripts\activate

# On macOS/Linux:
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

---

## Step 4: Final Check

Ensure your `Stokvel.json` **ABI file** is in the **root directory**.  
It **must match** the version of the contract deployed at `CONTRACT_ADDRESS`.

---

## Running the Application

The app has **two components** that must run **simultaneously** in **separate terminals**:

### 1. Start the Flask Web Server

Handles API, frontend, and database. **Start this first.**

```bash
# Terminal 1 (venv activated)
python app.py
```

### 2. Start the Listener Agent

Watches blockchain events and executes auto-funding.

```bash
# Terminal 2 (venv activated)
python listener.py
```

### 3. Access the DApp

Open your browser and go to:  
[http://127.0.0.1:5000](http://127.0.0.1:5000)

Connect your **Ronin Wallet** and start using the Stokvel!

---

## Project Structure

```plaintext
.
├── app.py                    # Flask web server
├── listener.py               # Event listener & auto-fund agent
├── requirements.txt          # Python dependencies
├── .env.example              # Environment template
├── Stokvel.json              # Contract ABI
├── static/                   # CSS, JS, images
├── templates/                # HTML templates
└── database.db               # SQLite (generated on first run)
```

## Agent Wallet Security

> **Important Security Note**  
> This project stores `AGENT_PRIVATE_KEY` in `.env` **for development simplicity only**.  
> **This is for development use only.**

### Best Practices:

- **For Development Only**: Use a dedicated wallet for the agent.
- **Minimal Funds**: Fund the agent wallet with **just enough RON** for gas (e.g., 0.1–0.5 RON).
- **Production**: Use a secure secrets manager:
  - AWS KMS
  - Google Cloud Secret Manager
  - HashiCorp Vault

---

*Built with ❤️ for community-driven finance on Ronin.*  