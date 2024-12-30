// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract LendingPool {
    struct Loan {
        address borrower;
        uint256 amount;
        uint256 interest;
        uint256 duration;
        uint256 deadline;
        string purpose;
        string proofLinks;
        bytes32 riskNote;
        bool active;
        bool repaid;
        uint256 totalYesVotes;
        mapping(address => uint256) lenderShares;
    }

    struct LoanRequest {
        address borrower;
        uint256 amount;
        uint256 interest;
        uint256 duration;
        string purpose;
        string proofLinks;
        bytes32 riskNote;
        uint256 votingDeadline;
        uint256 yesVotes;
        uint256 requiredVotes;
        bool executed;
        mapping(address => bool) hasVoted;
    }

    struct Staker {
        uint256 stakedAmount;
        uint256 lockedAmount;
        uint256 lastStakeTime;
    }

    mapping(address => Staker) public stakers;
    mapping(address => bool) public blacklisted;
    mapping(uint256 => Loan) public loans;
    mapping(uint256 => LoanRequest) public loanRequests;
    
    uint256 public totalStaked;
    uint256 public loanCount;
    uint256 public requestCount;
    uint256 public minStakeTime = 7 days;
    uint256 public approvalValidityPeriod = 30 days;

    event StakeAdded(address indexed staker, uint256 amount);
    event LoanRequested(uint256 indexed requestId, address indexed borrower);
    event VoteCast(uint256 indexed requestId, address indexed voter, bool vote);
    event LoanCreated(uint256 indexed loanId, address indexed borrower);
    event LoanRepaid(uint256 indexed loanId);
    event Blacklisted(address indexed borrower);

    receive() external payable {}

    function stake() external payable {
        require(msg.value > 0, "Stake required");
        Staker storage staker = stakers[msg.sender];
        staker.stakedAmount += msg.value;
        staker.lastStakeTime = block.timestamp;
        totalStaked += msg.value;
        emit StakeAdded(msg.sender, msg.value);
    }

    function requestLoan(
        uint256 amount,
        uint256 interest,
        uint256 duration,
        string calldata purpose,
        string calldata proofLinks,
        bytes32 riskNote
    ) external {
        require(!blacklisted[msg.sender], "Blacklisted");
        require(amount <= totalStaked, "Amount too high");

        uint256 requestId = requestCount++;
        LoanRequest storage request = loanRequests[requestId];
        request.borrower = msg.sender;
        request.amount = amount;
        request.interest = interest;
        request.duration = duration;
        request.purpose = purpose;
        request.proofLinks = proofLinks;
        request.riskNote = riskNote;
        request.votingDeadline = block.timestamp + 3 days;
        request.requiredVotes = amount * 60 / 100;

        emit LoanRequested(requestId, msg.sender);
    }

    function vote(uint256 requestId, bool support) external {
        LoanRequest storage request = loanRequests[requestId];
        Staker storage staker = stakers[msg.sender];
        
        require(block.timestamp < request.votingDeadline, "Voting ended");
        require(!request.hasVoted[msg.sender], "Already voted");
        require(staker.stakedAmount > 0, "No stake");
        require(block.timestamp >= staker.lastStakeTime + minStakeTime, "Stake too fresh");

        request.hasVoted[msg.sender] = true;
        if(support) {
            request.yesVotes += staker.stakedAmount;
        }

        emit VoteCast(requestId, msg.sender, support);

        if(support && request.yesVotes >= request.requiredVotes) {
            _createLoan(requestId);
        }
    }

    function _createLoan(uint256 requestId) internal {
        LoanRequest storage request = loanRequests[requestId];
        require(!request.executed, "Already executed");
        require(request.yesVotes >= request.requiredVotes, "Not enough votes");

        uint256 loanId = loanCount++;
        Loan storage loan = loans[loanId];
        loan.borrower = request.borrower;
        loan.amount = request.amount;
        loan.interest = request.interest;
        loan.duration = request.duration;
        loan.deadline = block.timestamp + request.duration;
        loan.purpose = request.purpose;
        loan.proofLinks = request.proofLinks;
        loan.riskNote = request.riskNote;
        loan.active = true;
        loan.totalYesVotes = request.yesVotes;

        request.executed = true;

        (bool sent, ) = payable(request.borrower).call{value: request.amount}("");
        require(sent, "Failed to send ETH");

        emit LoanCreated(loanId, request.borrower);
    }

    function repayLoan(uint256 loanId) external payable {
        Loan storage loan = loans[loanId];
        require(loan.active, "Not active");
        require(msg.value >= loan.amount + loan.interest, "Insufficient payment");

        loan.active = false;
        loan.repaid = true;

        uint256 totalAmount = loan.amount + loan.interest;
        uint256 baseShare = totalAmount / loan.totalYesVotes;

        address[] memory voters = getVoters(loanId);
        for(uint i = 0; i < voters.length; i++) {
            address voter = voters[i];
            if(loan.lenderShares[voter] > 0) {
                uint256 share = baseShare * loan.lenderShares[voter];
                (bool sent, ) = payable(voter).call{value: share}("");
                require(sent, "Failed to distribute");
            }
        }

        emit LoanRepaid(loanId);
    }

    function markAsDefaulted(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.active, "Not active");
        require(block.timestamp > loan.deadline, "Not expired");

        loan.active = false;
        blacklisted[loan.borrower] = true;
        
        emit Blacklisted(loan.borrower);
    }

    function getVoters(uint256 loanId) internal view returns (address[] memory) {
        LoanRequest storage request = loanRequests[loanId];
        uint256 voterCount = 0;
        address[] memory voters = new address[](100);

        for(uint i = 0; i < voters.length; i++) {
            if(request.hasVoted[voters[i]]) {
                voterCount++;
            }
        }

        address[] memory activeVoters = new address[](voterCount);
        uint256 index = 0;
        
        for(uint i = 0; i < voters.length; i++) {
            if(request.hasVoted[voters[i]]) {
                activeVoters[index] = voters[i];
                index++;
            }
        }

        return activeVoters;
    }

    function withdrawStake(uint256 amount) external {
        Staker storage staker = stakers[msg.sender];
        require(amount <= staker.stakedAmount - staker.lockedAmount, "Insufficient free stake");
        
        staker.stakedAmount -= amount;
        totalStaked -= amount;
        
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to withdraw");
    }
}

contract CreditVerification {
    struct VerificationRequest {
        address applicant;
        string documents;
        uint256 timestamp;
        bool verified;
        uint8 riskScore;
    }
    
    mapping(address => VerificationRequest) public verifications;
    mapping(address => bool) public verifiers;
    address public owner;
    
    constructor() {
        owner = msg.sender;
        verifiers[msg.sender] = true;
    }
    
    function requestVerification(string calldata documents) external {
        require(verifications[msg.sender].timestamp == 0, "Already requested");
        verifications[msg.sender] = VerificationRequest(msg.sender, documents, block.timestamp, false, 0);
    }
    
    function verify(address applicant, uint8 riskScore) external {
        require(verifiers[msg.sender], "Not verifier");
        require(riskScore <= 100, "Invalid score");
        
        VerificationRequest storage request = verifications[applicant];
        request.verified = true;
        request.riskScore = riskScore;
    }
    
    function addVerifier(address verifier) external {
        require(msg.sender == owner, "Not owner");
        verifiers[verifier] = true;
    }
    
    function removeVerifier(address verifier) external {
        require(msg.sender == owner, "Not owner");
        verifiers[verifier] = false;
    }
    
    function getRiskNote(address applicant) external view returns (bytes32) {
        VerificationRequest storage request = verifications[applicant];
        require(request.verified, "Not verified");
        return keccak256(abi.encodePacked(applicant, request.riskScore, request.timestamp));
    }
}
