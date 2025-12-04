// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Stokvel
 * @notice Decentralized Savings and Credit (Stokvel) Smart Contract
 * @dev Manages member administration, deposits, withdrawals, and P2P installment loans
 */
contract Stokvel {
    // ============ Constants ============
    uint256 public constant JOINING_FEE = 0.1 ether; // Non-withdrawable fee (0.1 RON on Ronin Saigon testnet)
    uint256 public constant LENDING_LIMIT_PERCENT = 70; // Max % of available savings a member can lend
    uint256 public constant COLLATERAL_PERCENT = 20; // Borrower collateral requirement
    uint256 public constant INTEREST_RATE_APR = 30; // Annual interest rate (30%)
    uint256 public constant LOAN_TERM_MONTHS = 12; // Fixed term
    uint256 public constant LATE_FEE_PERCENT = 5; // Penalty per late period (5%)
    uint256 public constant INSTALLMENT_PERIOD = 30 days; // 30 days per installment period

    // ============ State Variables ============
    address public creator; // Deployer/Admin
    uint256 public totalMembers; // Total active members count
    uint256 public nextLoanId; // Auto-incrementing loan ID

    // ============ Data Structures ============
    
    struct Member {
        bool isActive;
        bytes32 hashedId;
        uint256 totalSavings;
        uint256 amountLentOut;
        uint256 amountLockedCollateral;
        mapping(address => bool) hasVotedOnApplicant; // Track if member has voted
        mapping(address => bool) voteDirection; // true = positive, false = negative
    }

    struct Installment {
        uint256 dueDate;
        uint256 amountDue;
        uint256 lateFeesAccrued;
        bool isPaid;
    }

    struct Loan {
        uint256 loanId;
        address borrower;
        uint256 amountRequested;
        uint256 amountFunded;
        uint256 collateralLocked;
        uint256 totalInterest;
        bool isActive;
        bool isDefaulted;
        mapping(address => uint256) lenders;
        address[] lenderList;
        Installment[12] installments;
        uint256 nextInstallmentIndex;
        uint256 createdAt;
    }

    // ============ Mappings ============
    mapping(address => Member) public members;
    mapping(uint256 => Loan) public loans;
    mapping(bytes32 => bool) public isBlacklisted;
    mapping(address => bytes32) public applicantHashedIds; // Track applicant IDs before activation
    mapping(address => uint256) public applicantPositiveVotes; // Track positive votes per applicant
    mapping(address => uint256) public applicantNegativeVotes; // Track negative votes per applicant
    mapping(address => bool) public creatorVoteOnApplicant; // Creator's vote: true = positive, false = negative, undefined = not voted
    mapping(address => bool) public creatorHasVoted; // Track if creator has voted on applicant
    mapping(bytes32 => address) public hashedIdToAddress; // Track which address uses which hashed ID

    // ============ Events ============
    event ClubCreated(address indexed creator, bytes32 indexed hashedId);
    event ApplicationSubmitted(address indexed applicant, bytes32 indexed hashedId);
    event VoteCast(address indexed voter, address indexed applicant, bool isPositive);
    event ApplicantApproved(address indexed applicant);
    event ApplicantRejected(address indexed applicant);
    event MemberActivated(address indexed member, bytes32 indexed hashedId);
    event Deposit(address indexed member, uint256 amount);
    event Withdrawal(address indexed member, uint256 amount);
    event AccountClosed(address indexed member, uint256 amount);
    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amountRequested);
    event LoanFunded(uint256 indexed loanId, address indexed lender, uint256 amount);
    event LoanDisbursed(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event PaymentMade(uint256 indexed loanId, uint256 installmentIndex, uint256 amount);
    event LoanDefaulted(uint256 indexed loanId, address indexed borrower);
    event MemberBlacklisted(address indexed borrower, bytes32 indexed hashedId);

    // ============ Errors ============
    error InsufficientJoiningFee();
    error AlreadyBlacklisted();
    error DuplicateId();
    error NotActiveMember();
    error AlreadyVoted();
    error NotApproved();
    error InsufficientActivationFee();
    error InsufficientAvailableSavings();
    error CannotCloseAccount();
    error InsufficientCollateral();
    error LoanNotFound();
    error LoanAlreadyActive();
    error LoanNotFullyFunded();
    error InvalidPaymentAmount();
    error LoanAlreadyDefaulted();
    error NoDefaultDetected();
    error InvalidApplicant();

    // ============ Modifiers ============
    modifier onlyActiveMember() {
        if (!members[msg.sender].isActive) revert NotActiveMember();
        _;
    }

    modifier onlyCreator() {
        require(msg.sender == creator, "Only creator");
        _;
    }

    // ============ Constructor ============
    /**
     * @notice Creates the Stokvel club
     * @param idString Real-world identifier string for the creator
     * @notice On Ronin Saigon testnet, 0.1 ether = 0.1 RON
     * @notice Payment must be >= JOINING_FEE. Excess amount is added to totalSavings.
     */
    constructor(string memory idString) payable {
        if (msg.value < JOINING_FEE) revert InsufficientJoiningFee();
        
        creator = msg.sender;
        bytes32 hashedId = keccak256(abi.encodePacked(idString));
        
        Member storage newMember = members[msg.sender];
        newMember.isActive = true;
        newMember.hashedId = hashedId;
        newMember.totalSavings = msg.value; // Include any excess amount
        
        hashedIdToAddress[hashedId] = msg.sender;
        totalMembers = 1;
        
        emit ClubCreated(msg.sender, hashedId);
    }

    // ============ Helper Functions ============
    
    /**
     * @notice Calculate available savings for a member
     * @param memberAddress Address of the member
     * @return Available amount that can be withdrawn or lent
     * @notice totalSavings already excludes amountLentOut (reduced when lending)
     */
    function getAvailableSavings(address memberAddress) public view returns (uint256) {
        Member storage member = members[memberAddress];
        if (!member.isActive) return 0;
        
        // totalSavings already excludes lent out funds, so we only subtract joining fee and collateral
        return member.totalSavings - JOINING_FEE - member.amountLockedCollateral;
    }

    /**
     * @notice Check if an applicant is approved
     * @param applicant Address of the applicant
     * @return True if approved, false if rejected, undefined if decision not yet made
     * @dev Voting logic: Creator has veto power. If creator votes NO, reject. If creator votes YES, need 50% of other members to vote, then positive > negative.
     */
    function isApplicantApproved(address applicant) public view returns (bool) {
        // If creator hasn't voted yet, no decision can be made
        if (!creatorHasVoted[applicant]) {
            return false; // Not approved yet (pending)
        }
        
        // If creator voted NO, applicant is rejected regardless of other votes
        if (!creatorVoteOnApplicant[applicant]) {
            return false; // Rejected
        }
        
        // Creator voted YES, now check other members' votes
        uint256 otherMembers = totalMembers - 1; // Exclude creator
        if (otherMembers == 0) {
            // Only creator exists, so if creator voted yes, approve
            return true;
        }
        
        uint256 totalOtherVotes = applicantPositiveVotes[applicant] + applicantNegativeVotes[applicant];
        uint256 requiredVotes = (otherMembers + 1) / 2; // 50% rounded up
        
        // Need at least 50% of other members to vote
        if (totalOtherVotes < requiredVotes) {
            return false; // Not enough votes yet (pending)
        }
        
        // Decision: positive votes must exceed negative votes
        return applicantPositiveVotes[applicant] > applicantNegativeVotes[applicant];
    }
    
    /**
     * @notice Check if a voting decision has been made (approved or rejected)
     * @param applicant Address of the applicant
     * @return True if a final decision has been made
     */
    function hasVotingDecision(address applicant) public view returns (bool) {
        if (!creatorHasVoted[applicant]) {
            return false; // Creator hasn't voted, no decision
        }
        
        // If creator voted NO, decision is made (rejected)
        if (!creatorVoteOnApplicant[applicant]) {
            return true; // Rejected
        }
        
        // Creator voted YES, check if enough other members have voted
        uint256 otherMembers = totalMembers - 1;
        if (otherMembers == 0) {
            return true; // Only creator, decision made
        }
        
        uint256 totalOtherVotes = applicantPositiveVotes[applicant] + applicantNegativeVotes[applicant];
        uint256 requiredVotes = (otherMembers + 1) / 2; // 50% rounded up
        
        return totalOtherVotes >= requiredVotes; // Decision made if 50%+ have voted
    }

    // ============ Member Management Functions ============
    
    /**
     * @notice Apply to join the Stokvel
     * @param idString Real-world identifier string
     */
    function applyToJoin(string memory idString) external {
        bytes32 hashedId = keccak256(abi.encodePacked(idString));
        
        // Blacklist check
        if (isBlacklisted[hashedId]) revert AlreadyBlacklisted();
        
        // Duplicate ID check
        address existingMember = hashedIdToAddress[hashedId];
        if (existingMember != address(0) && members[existingMember].isActive) {
            revert DuplicateId();
        }
        
        // Store applicant's hashed ID
        applicantHashedIds[msg.sender] = hashedId;
        
        emit ApplicationSubmitted(msg.sender, hashedId);
    }

    /**
     * @notice Vote on an applicant
     * @param applicant Address of the applicant
     * @param isPositive True for positive vote (approve), false for negative vote (reject)
     * @dev Members can vote positively or negatively. Creator has veto power.
     */
    function voteOnApplicant(address applicant, bool isPositive) external onlyActiveMember {
        if (applicantHashedIds[applicant] == bytes32(0)) revert InvalidApplicant();
        
        // One vote per applicant per member
        if (members[msg.sender].hasVotedOnApplicant[applicant]) revert AlreadyVoted();
        
        members[msg.sender].hasVotedOnApplicant[applicant] = true;
        members[msg.sender].voteDirection[applicant] = isPositive;
        
        // Handle creator vote separately
        if (msg.sender == creator) {
            creatorHasVoted[applicant] = true;
            creatorVoteOnApplicant[applicant] = isPositive;
            
            // If creator votes NO, applicant is immediately rejected
            if (!isPositive) {
                emit VoteCast(msg.sender, applicant, isPositive);
                emit ApplicantRejected(applicant);
                return;
            }
            // Creator voted YES, continue to check other members' votes
        } else {
            // Regular member vote
            if (isPositive) {
                applicantPositiveVotes[applicant]++;
            } else {
                applicantNegativeVotes[applicant]++;
            }
        }
        
        emit VoteCast(msg.sender, applicant, isPositive);
        
        // Check if decision has been made after this vote
        if (hasVotingDecision(applicant)) {
            if (isApplicantApproved(applicant)) {
                emit ApplicantApproved(applicant);
            } else {
                // This case handles: creator voted YES but negative votes >= positive votes
                emit ApplicantRejected(applicant);
            }
        }
    }

    /**
     * @notice Activate membership after approval
     * @notice Payment must be >= JOINING_FEE. Excess amount is added to totalSavings.
     */
    function activateMembership() external payable {
        if (msg.value < JOINING_FEE) revert InsufficientActivationFee();
        if (!isApplicantApproved(msg.sender)) revert NotApproved();
        
        bytes32 hashedId = applicantHashedIds[msg.sender];
        if (hashedId == bytes32(0)) revert InvalidApplicant();
        
        Member storage newMember = members[msg.sender];
        newMember.isActive = true;
        newMember.hashedId = hashedId;
        newMember.totalSavings = msg.value; // Include any excess amount
        
        hashedIdToAddress[hashedId] = msg.sender;
        totalMembers++;
        
        // Clean up applicant data
        delete applicantHashedIds[msg.sender];
        delete applicantPositiveVotes[msg.sender];
        delete applicantNegativeVotes[msg.sender];
        delete creatorHasVoted[msg.sender];
        delete creatorVoteOnApplicant[msg.sender];
        
        emit MemberActivated(msg.sender, hashedId);
    }

    // ============ Fund Management Functions ============
    
    /**
     * @notice Deposit ETH to savings
     */
    function deposit() external payable onlyActiveMember {
        if (msg.value == 0) revert InvalidPaymentAmount();
        
        members[msg.sender].totalSavings += msg.value;
        
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw available savings
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external onlyActiveMember {
        uint256 available = getAvailableSavings(msg.sender);
        if (amount > available) revert InsufficientAvailableSavings();
        
        members[msg.sender].totalSavings -= amount;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Withdrawal(msg.sender, amount);
    }

    // ============ Account Closure ============
    
    /**
     * @notice Close account and withdraw all funds
     * @notice Returns all available savings plus the joining fee
     */
    function closeAccount() external onlyActiveMember {
        Member storage member = members[msg.sender];
        
        // Safety lock
        if (member.amountLentOut > 0 || member.amountLockedCollateral > 0) {
            revert CannotCloseAccount();
        }
        
        // Calculate total to withdraw = available savings + joining fee
        uint256 available = getAvailableSavings(msg.sender);
        uint256 totalToWithdraw = available + JOINING_FEE;
        
        // Transfer funds FIRST - if this fails, transaction reverts and state remains unchanged
        (bool success, ) = payable(msg.sender).call{value: totalToWithdraw}("");
        require(success, "Transfer failed");
        
        // Only update state AFTER successful transfer
        member.isActive = false;
        member.totalSavings = 0;
        totalMembers--;
        
        emit AccountClosed(msg.sender, totalToWithdraw);
    }

    // ============ Loan Functions ============
    
    /**
     * @notice Request a loan
     * @param amountRequested Total principal amount requested
     * @return loanId The ID of the created loan
     */
    function requestLoan(uint256 amountRequested) external onlyActiveMember returns (uint256) {
        if (amountRequested == 0) revert InvalidPaymentAmount();
        
        Member storage borrower = members[msg.sender];
        
        // Collateral check
        uint256 requiredCollateral = (amountRequested * COLLATERAL_PERCENT) / 100;
        uint256 available = getAvailableSavings(msg.sender);
        if (available < requiredCollateral) revert InsufficientCollateral();
        
        // Lock collateral
        borrower.amountLockedCollateral += requiredCollateral;
        
        // Create loan
        uint256 loanId = nextLoanId++;
        Loan storage loan = loans[loanId];
        loan.loanId = loanId;
        loan.borrower = msg.sender;
        loan.amountRequested = amountRequested;
        loan.collateralLocked = requiredCollateral;
        loan.createdAt = block.timestamp;
        
        // Calculate loan terms
        loan.totalInterest = (amountRequested * INTEREST_RATE_APR) / 100;
        uint256 totalRepayment = amountRequested + loan.totalInterest;
        uint256 monthlyInstallmentAmount = totalRepayment / LOAN_TERM_MONTHS;
        
        // Calculate remainder
        uint256 remainder = totalRepayment - (monthlyInstallmentAmount * LOAN_TERM_MONTHS);
        
        // Set installments
        uint256 firstDueDate = block.timestamp + INSTALLMENT_PERIOD;
        for (uint256 i = 0; i < LOAN_TERM_MONTHS; i++) {
            loan.installments[i].dueDate = firstDueDate + (i * INSTALLMENT_PERIOD);
            if (i < 11) {
                loan.installments[i].amountDue = monthlyInstallmentAmount;
            } else {
                // Last installment includes remainder
                loan.installments[i].amountDue = monthlyInstallmentAmount + remainder;
            }
        }
        
        emit LoanRequested(loanId, msg.sender, amountRequested);
        return loanId;
    }

    /**
     * @notice Fund a loan from existing savings balance
     * @param loanId ID of the loan to fund
     * @param amount Amount to fund from available savings
     * @notice Funds come from lender's existing savings balance, not a new deposit
     */
    function fundLoan(uint256 loanId, uint256 amount) external onlyActiveMember {
        if (amount == 0) revert InvalidPaymentAmount();
        
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.isActive) revert LoanAlreadyActive();
        if (loan.isDefaulted) revert LoanAlreadyDefaulted();
        if (msg.sender == loan.borrower) revert InvalidApplicant(); // Can't fund own loan
        
        uint256 remainingNeeded = loan.amountRequested - loan.amountFunded;
        uint256 fundingAmount = amount > remainingNeeded ? remainingNeeded : amount;
        
        Member storage lender = members[msg.sender];
        
        // Lender limit check - must have enough available savings
        uint256 available = getAvailableSavings(msg.sender);
        uint256 maxLendable = (available * LENDING_LIMIT_PERCENT) / 100;
        if (fundingAmount > maxLendable) revert InsufficientAvailableSavings();
        
        // Check that lender has enough available savings
        if (fundingAmount > available) revert InsufficientAvailableSavings();
        
        // Lock lender funds - remove from totalSavings and track in amountLentOut
        lender.amountLentOut += fundingAmount;
        lender.totalSavings -= fundingAmount; // Remove from savings since funds are now lent out
        
        // Record lender
        if (loan.lenders[msg.sender] == 0) {
            loan.lenderList.push(msg.sender);
        }
        loan.lenders[msg.sender] += fundingAmount;
        loan.amountFunded += fundingAmount;
        
        emit LoanFunded(loanId, msg.sender, fundingAmount);
        
        // Fully funded - disburse first, then activate
        if (loan.amountFunded == loan.amountRequested) {
            // Disburse to borrower FIRST - if this fails, transaction reverts and loan stays inactive
            (bool success, ) = payable(loan.borrower).call{value: loan.amountRequested}("");
            require(success, "Disbursement failed");
            
            // Only mark as active AFTER successful disbursement
            loan.isActive = true;
            
            // Due dates are already set in requestLoan function
            
            emit LoanDisbursed(loanId, loan.borrower, loan.amountRequested);
        }
    }

    /**
     * @notice Make a monthly payment on a loan
     * @param loanId ID of the loan
     */
    function makeMonthlyPayment(uint256 loanId) external payable {
        if (msg.value == 0) revert InvalidPaymentAmount();
        
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (!loan.isActive) revert LoanNotFullyFunded();
        if (loan.isDefaulted) revert LoanAlreadyDefaulted();
        if (msg.sender != loan.borrower) revert InvalidApplicant();
        
        uint256 currentIndex = loan.nextInstallmentIndex;
        if (currentIndex >= LOAN_TERM_MONTHS) revert InvalidPaymentAmount(); // Loan already paid
        
        Installment storage installment = loan.installments[currentIndex];
        if (installment.isPaid) revert InvalidPaymentAmount(); // Already paid
        
        // Calculate late fees
        if (block.timestamp > installment.dueDate) {
            uint256 daysLate = (block.timestamp - installment.dueDate) / (30 days);
            uint256 lateFee = (installment.amountDue * LATE_FEE_PERCENT * daysLate) / 100;
            installment.lateFeesAccrued = lateFee;
        }
        
        uint256 totalDue = installment.amountDue + installment.lateFeesAccrued;
        
        if (msg.value != totalDue) revert InvalidPaymentAmount();
        
        uint256 totalPrincipal = loan.amountRequested;
        uint256 principalPortion = loan.amountRequested / LOAN_TERM_MONTHS;
        uint256 interestPortion = loan.totalInterest / LOAN_TERM_MONTHS;
        
        if (currentIndex == 11) {
            uint256 principalRemainder = loan.amountRequested - (principalPortion * 11);
            uint256 interestRemainder = loan.totalInterest - (interestPortion * 11);
            principalPortion += principalRemainder;
            interestPortion += interestRemainder;
        }
        
        for (uint256 i = 0; i < loan.lenderList.length; i++) {
            address lenderAddress = loan.lenderList[i];
            uint256 lenderPrincipal = loan.lenders[lenderAddress];
            
            if (lenderPrincipal > 0) {
                uint256 lenderPrincipalPortion = (principalPortion * lenderPrincipal) / totalPrincipal;
                uint256 lenderInterestPortion = (interestPortion * lenderPrincipal) / totalPrincipal;
                uint256 lenderLateFeePortion = (installment.lateFeesAccrued * lenderPrincipal) / totalPrincipal;
                
                Member storage lender = members[lenderAddress];
                
                lender.amountLentOut -= lenderPrincipalPortion;
                lender.totalSavings += lenderPrincipalPortion;
                lender.totalSavings += lenderInterestPortion + lenderLateFeePortion;
            }
        }
        
        installment.isPaid = true;
        loan.nextInstallmentIndex++;
        
        emit PaymentMade(loanId, currentIndex, totalDue);
    }

    /**
     * @notice Check if a loan has defaulted and handle default
     * @param loanId ID of the loan to check
     */
    function checkLoanDefault(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (!loan.isActive) revert LoanNotFullyFunded();
        if (loan.isDefaulted) revert LoanAlreadyDefaulted();
        
        uint256 missedCount = 0;
        uint256 currentIndex = loan.nextInstallmentIndex;
        
        for (uint256 i = currentIndex; i < LOAN_TERM_MONTHS; i++) {
            if (block.timestamp > loan.installments[i].dueDate) {
                missedCount++;
            } else {
                break;
            }
        }
        
        for (uint256 i = 0; i < currentIndex; i++) {
            if (!loan.installments[i].isPaid && block.timestamp > loan.installments[i].dueDate) {
                missedCount++;
            }
        }
        
        if (missedCount < 3) revert NoDefaultDetected();
        
        loan.isDefaulted = true;
        
        Member storage borrower = members[loan.borrower];
        
        uint256 collateralToSeize = loan.collateralLocked;
        borrower.amountLockedCollateral -= collateralToSeize;
        borrower.totalSavings -= collateralToSeize;
        
        uint256 totalPrincipal = loan.amountRequested;
        for (uint256 i = 0; i < loan.lenderList.length; i++) {
            address lenderAddress = loan.lenderList[i];
            uint256 lenderPrincipal = loan.lenders[lenderAddress];
            
            if (lenderPrincipal > 0) {
                uint256 collateralShare = (collateralToSeize * lenderPrincipal) / totalPrincipal;
                Member storage lender = members[lenderAddress];
                
                lender.totalSavings += collateralShare;
                lender.amountLentOut -= lenderPrincipal;
            }
        }
        
        borrower.isActive = false;
        totalMembers--;
        
        bytes32 hashedId = borrower.hashedId;
        isBlacklisted[hashedId] = true;
        
        emit LoanDefaulted(loanId, loan.borrower);
        emit MemberBlacklisted(loan.borrower, hashedId);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get member information
     */
    function getMember(address memberAddress) external view returns (
        bool isActive,
        bytes32 hashedId,
        uint256 totalSavings,
        uint256 amountLentOut,
        uint256 amountLockedCollateral,
        uint256 availableSavings
    ) {
        Member storage member = members[memberAddress];
        return (
            member.isActive,
            member.hashedId,
            member.totalSavings,
            member.amountLentOut,
            member.amountLockedCollateral,
            getAvailableSavings(memberAddress)
        );
    }

    /**
     * @notice Get loan information
     */
    function getLoan(uint256 loanId) external view returns (
        address borrower,
        uint256 amountRequested,
        uint256 amountFunded,
        uint256 collateralLocked,
        uint256 totalInterest,
        bool isActive,
        bool isDefaulted,
        uint256 nextInstallmentIndex,
        uint256 createdAt
    ) {
        Loan storage loan = loans[loanId];
        return (
            loan.borrower,
            loan.amountRequested,
            loan.amountFunded,
            loan.collateralLocked,
            loan.totalInterest,
            loan.isActive,
            loan.isDefaulted,
            loan.nextInstallmentIndex,
            loan.createdAt
        );
    }

    /**
     * @notice Get installment information
     */
    function getInstallment(uint256 loanId, uint256 index) external view returns (
        uint256 dueDate,
        uint256 amountDue,
        uint256 lateFeesAccrued,
        bool isPaid
    ) {
        Loan storage loan = loans[loanId];
        require(index < LOAN_TERM_MONTHS, "Invalid installment index");
        Installment storage installment = loan.installments[index];
        return (
            installment.dueDate,
            installment.amountDue,
            installment.lateFeesAccrued,
            installment.isPaid
        );
    }

    /**
     * @notice Get lender information for a loan
     */
    function getLenderAmount(uint256 loanId, address lender) external view returns (uint256) {
        return loans[loanId].lenders[lender];
    }

    /**
     * @notice Get all lenders for a loan
     */
    function getLenderList(uint256 loanId) external view returns (address[] memory) {
        return loans[loanId].lenderList;
    }

    /**
     * @notice Get total number of active loans
     */
    function getTotalLoans() external view returns (uint256) {
        return nextLoanId;
    }

    /**
     * @notice Get voting status for an applicant
     * @param applicant Address of the applicant
     * @return positiveVotes Number of positive votes from other members
     * @return negativeVotes Number of negative votes from other members
     * @return creatorVoted Whether creator has voted
     * @return creatorVotePositive Creator's vote (true = positive, false = negative, only valid if creatorVoted is true)
     * @return totalOtherMembers Total number of other members (excluding creator)
     * @return requiredVotes Minimum votes needed (50% of other members)
     * @return decisionMade Whether a final decision has been made
     * @return approved Whether applicant is approved (only valid if decisionMade is true)
     */
    function getApplicantVotingStatus(address applicant) external view returns (
        uint256 positiveVotes,
        uint256 negativeVotes,
        bool creatorVoted,
        bool creatorVotePositive,
        uint256 totalOtherMembers,
        uint256 requiredVotes,
        bool decisionMade,
        bool approved
    ) {
        positiveVotes = applicantPositiveVotes[applicant];
        negativeVotes = applicantNegativeVotes[applicant];
        creatorVoted = creatorHasVoted[applicant];
        creatorVotePositive = creatorVoteOnApplicant[applicant];
        totalOtherMembers = totalMembers > 1 ? totalMembers - 1 : 0;
        requiredVotes = totalOtherMembers > 0 ? (totalOtherMembers + 1) / 2 : 0;
        decisionMade = hasVotingDecision(applicant);
        approved = isApplicantApproved(applicant);
    }
    
    /**
     * @notice Check if a specific member has already voted on an applicant
     * @param memberAddress The address of the member to check
     * @param applicantAddress The address of the applicant
     * @return True if the member has voted, false otherwise
     */
    function hasMemberVoted(address memberAddress, address applicantAddress) external view returns (bool) {
        return members[memberAddress].hasVotedOnApplicant[applicantAddress];
    }
}