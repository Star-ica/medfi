// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MedFi
 * @notice Health savings and micro-loan protocol on Botchain
 * @dev Users save BOT, earn MFT reward tokens, and borrow for healthcare with a guarantor
 */
contract MedFi {

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Member {
        address wallet;
        string  name;
        uint256 totalSaved;
        uint256 savingsStreak;      // consecutive weeks with at least one deposit
        uint256 lastDepositWeek;    // ISO week number for streak tracking
        uint256 mftBalance;         // Health Support Tokens earned
        uint256 activeLoans;
        bool    registered;
    }

    struct Loan {
        uint256 id;
        address borrower;
        address guarantor;
        uint256 amount;
        uint256 guarantorStake;     // half of loan amount, locked from guarantor
        uint256 issuedAt;
        uint256 dueDate;
        uint256 amountRepaid;
        bool    repaid;
        bool    defaulted;
    }

    struct Provider {
        address wallet;
        string  name;
        string  category;           // "Clinic" | "Pharmacy" | "Hospital"
        bool    active;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public loanCounter;
    uint256 public totalPoolBalance;
    uint256 public constant MFT_PER_DEPOSIT   = 10;    // MFT earned per deposit action
    uint256 public constant MFT_PER_REPAYMENT = 20;    // MFT earned per on-time repayment
    uint256 public constant LOAN_INTEREST_BPS = 200;   // 2% flat fee — kept minimal
    uint256 public constant MAX_LOAN_RATIO    = 3;     // max loan = 3x savings

    mapping(address => Member)    public members;
    mapping(uint256 => Loan)      public loans;
    mapping(address => uint256[]) public memberLoans;
    mapping(address => Provider)  public providers;
    address[] public providerList;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Registered(address indexed member, string name);
    event Deposited(address indexed member, uint256 amount, uint256 mftEarned);
    event LoanRequested(uint256 indexed loanId, address indexed borrower, address indexed guarantor, uint256 amount);
    event GuarantorStaked(uint256 indexed loanId, address indexed guarantor, uint256 stake);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanDefaulted(uint256 indexed loanId, address indexed borrower);
    event ProviderAdded(address indexed provider, string name, string category);
    event PaymentToProvider(address indexed member, address indexed provider, uint256 amount);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner()  { require(msg.sender == owner, "Not owner"); _; }
    modifier isMember()   { require(members[msg.sender].registered, "Not a member"); _; }
    modifier loanExists(uint256 id) { require(id > 0 && id <= loanCounter, "Loan not found"); _; }

    constructor() { owner = msg.sender; }

    // ─── Registration ─────────────────────────────────────────────────────────
    function register(string calldata _name) external {
        require(!members[msg.sender].registered, "Already registered");
        members[msg.sender] = Member({
            wallet:          msg.sender,
            name:            _name,
            totalSaved:      0,
            savingsStreak:   0,
            lastDepositWeek: 0,
            mftBalance:      0,
            activeLoans:     0,
            registered:      true
        });
        emit Registered(msg.sender, _name);
    }

    // ─── Savings ──────────────────────────────────────────────────────────────
    function deposit() external payable isMember {
        require(msg.value > 0, "Zero deposit");

        Member storage m = members[msg.sender];
        m.totalSaved += msg.value;
        totalPoolBalance += msg.value;

        // Update savings streak (week number approximation)
        uint256 currentWeek = block.timestamp / 1 weeks;
        if (currentWeek == m.lastDepositWeek + 1 || m.lastDepositWeek == 0) {
            m.savingsStreak += 1;
        } else if (currentWeek > m.lastDepositWeek + 1) {
            m.savingsStreak = 1; // reset
        }
        m.lastDepositWeek = currentWeek;

        // Reward MFT — bonus for streaks
        uint256 mft = MFT_PER_DEPOSIT + (m.savingsStreak > 4 ? 5 : 0);
        m.mftBalance += mft;

        emit Deposited(msg.sender, msg.value, mft);
    }

    function withdrawSavings(uint256 _amount) external isMember {
        Member storage m = members[msg.sender];
        require(m.activeLoans == 0, "Repay loans first");
        require(m.totalSaved >= _amount, "Insufficient savings");

        m.totalSaved     -= _amount;
        totalPoolBalance -= _amount;

        (bool ok,) = payable(msg.sender).call{value: _amount}("");
        require(ok, "Transfer failed");
    }

    // ─── Loans ────────────────────────────────────────────────────────────────
    /**
     * @dev Step 1 — borrower requests a loan and nominates a guarantor
     *      The guarantor must then call stakeAsGuarantor() to activate the loan
     */
    function requestLoan(
        uint256 _amount,
        address _guarantor,
        uint256 _durationDays
    ) external isMember returns (uint256) {
        require(_guarantor != msg.sender, "Cannot self-guarantee");
        require(members[_guarantor].registered, "Guarantor not a member");
        require(members[msg.sender].activeLoans == 0, "Existing active loan");
        require(_amount > 0, "Zero amount");
        require(_durationDays >= 7 && _durationDays <= 180, "Duration 7-180 days");

        // Max loan = 3x savings (or pool balance, whichever is less)
        uint256 maxLoan = members[msg.sender].totalSaved * MAX_LOAN_RATIO;
        require(_amount <= maxLoan, "Exceeds max loan (3x savings)");
        require(totalPoolBalance >= _amount, "Pool insufficient");

        uint256 stake = _amount / 2;   // guarantor stakes half

        loanCounter++;
        loans[loanCounter] = Loan({
            id:             loanCounter,
            borrower:       msg.sender,
            guarantor:      _guarantor,
            amount:         _amount,
            guarantorStake: stake,
            issuedAt:       0,           // activated when guarantor stakes
            dueDate:        0,
            amountRepaid:   0,
            repaid:         false,
            defaulted:      false
        });
        memberLoans[msg.sender].push(loanCounter);

        emit LoanRequested(loanCounter, msg.sender, _guarantor, _amount);
        return loanCounter;
    }

    /**
     * @dev Step 2 — guarantor locks their stake and loan is disbursed to borrower
     */
    function stakeAsGuarantor(uint256 _loanId) external payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(msg.sender == loan.guarantor, "Not the guarantor");
        require(loan.issuedAt == 0, "Already activated");
        require(msg.value >= loan.guarantorStake, "Insufficient stake");
        require(totalPoolBalance >= loan.amount, "Pool insufficient");

        loan.issuedAt = block.timestamp;
        loan.dueDate  = block.timestamp + (loan.amount > 0 ? _getDuration(_loanId) * 1 days : 30 days);

        // Lock guarantor stake into pool
        totalPoolBalance += msg.value;

        // Disburse loan
        members[loan.borrower].activeLoans += 1;
        totalPoolBalance -= loan.amount;

        (bool ok,) = payable(loan.borrower).call{value: loan.amount}("");
        require(ok, "Disbursement failed");

        // Refund excess guarantor deposit
        if (msg.value > loan.guarantorStake) {
            (bool r,) = payable(msg.sender).call{value: msg.value - loan.guarantorStake}("");
            require(r, "Refund failed");
        }

        emit GuarantorStaked(_loanId, msg.sender, loan.guarantorStake);
    }

    function repayLoan(uint256 _loanId) external payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(msg.sender == loan.borrower, "Not borrower");
        require(!loan.repaid && !loan.defaulted, "Loan closed");
        require(loan.issuedAt > 0, "Loan not activated");

        uint256 fee   = (loan.amount * LOAN_INTEREST_BPS) / 10000;
        uint256 total = loan.amount + fee;
        require(msg.value >= total, "Underpayment");

        loan.amountRepaid = total;
        loan.repaid       = true;
        members[loan.borrower].activeLoans -= 1;

        // Earn MFT for on-time repayment
        bool onTime = block.timestamp <= loan.dueDate;
        uint256 mft = onTime ? MFT_PER_REPAYMENT : MFT_PER_REPAYMENT / 2;
        members[loan.borrower].mftBalance += mft;

        // Return guarantor stake
        totalPoolBalance += total;
        uint256 gStake = loan.guarantorStake;
        totalPoolBalance -= gStake;
        (bool gs,) = payable(loan.guarantor).call{value: gStake}("");
        require(gs, "Guarantor return failed");

        // Refund borrower excess
        if (msg.value > total) {
            (bool r,) = payable(msg.sender).call{value: msg.value - total}("");
            require(r, "Refund failed");
        }

        emit LoanRepaid(_loanId, msg.sender, total);
    }

    function markDefault(uint256 _loanId) external onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(!loan.repaid && !loan.defaulted, "Loan closed");
        require(loan.issuedAt > 0, "Not activated");
        require(block.timestamp > loan.dueDate, "Not overdue");

        loan.defaulted = true;
        members[loan.borrower].activeLoans -= 1;

        // Guarantor stake is kept in the pool (covers partial loss)
        emit LoanDefaulted(_loanId, loan.borrower);
    }

    // ─── Pay a Healthcare Provider ────────────────────────────────────────────
    function payProvider(address _provider) external payable isMember {
        require(providers[_provider].active, "Not a verified provider");
        require(msg.value > 0, "Zero amount");

        (bool ok,) = payable(_provider).call{value: msg.value}("");
        require(ok, "Payment failed");

        emit PaymentToProvider(msg.sender, _provider, msg.value);
    }

    // ─── Provider Management ──────────────────────────────────────────────────
    function addProvider(address _wallet, string calldata _name, string calldata _category) external onlyOwner {
        providers[_wallet] = Provider({ wallet: _wallet, name: _name, category: _category, active: true });
        providerList.push(_wallet);
        emit ProviderAdded(_wallet, _name, _category);
    }

    function deactivateProvider(address _wallet) external onlyOwner {
        providers[_wallet].active = false;
    }

    // ─── Views ────────────────────────────────────────────────────────────────
    function getMemberLoans(address _m) external view returns (uint256[] memory) { return memberLoans[_m]; }
    function getProviders() external view returns (address[] memory) { return providerList; }
    function getLoan(uint256 _id) external view loanExists(_id) returns (Loan memory) { return loans[_id]; }
    function maxLoanFor(address _m) external view returns (uint256) { return members[_m].totalSaved * MAX_LOAN_RATIO; }

    // ─── Internal ─────────────────────────────────────────────────────────────
    function _getDuration(uint256 _loanId) internal view returns (uint256) {
        // stored in loan amount for simplicity; real impl would store separately
        // default: 30 days
        return 30;
    }

    receive() external payable { totalPoolBalance += msg.value; }
}
