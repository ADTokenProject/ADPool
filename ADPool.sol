// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


// Have fun reading it. Hopefully it's bug-free. God bless.
contract ADPool is Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // LP token contract address
        uint256 allocPoint; // How many allocation points are allocated to this pool. AD is allocated to each block.
        uint256 lastRewardBlock; // The last block number in which an AD allocation occurred.
        uint256 accAdPerShare; //Accumulated AD per share, times 1e12. See below.
    }

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens are provided by the user
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of AD
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAdPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accAdPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    //User reward info
    struct RewardInfo {
        uint256 rewardTotal;    //The total amount of rewards accumulated in all the pools of the user (excluding the rewards I recommended)
        uint256 rewardLocked;    //Locked rewards: can be extracted only after unlocking
        address referrer; //The person who recommended me
        uint256 referrerRewardTotal; //Rewards for my referrals: only increased, not decreased, for presentation, and the actual amount added to the lock
        address[] referrals;//Someone I recommend
        RewardUnlock[] rewardUnlocks;   //List of rewards in unlock
    }

    //Rewards in unlocks
    struct RewardUnlock {
        uint256 rewardAmount;//Award amount: record
        uint256 depositAmount;//The amount of deposit used to unlock rewards
        uint256 totalAmount; //Total amount, unchanged = rewardAmount+depositAmount
        uint256 extractTotalAmount; //DepositAmount (rewardAmount+depositAmount), can only be taken when the time is up and subtracted each time until it reaches 0;
        uint256 startTime;
        uint256 endTime;
    }

    // The AD TOKEN
    IERC20 public adToken;
    //Total bonus for all mine pools (unchanged)
    uint256 public rewardAmountTotal;
    //Total amount of residual rewards allocated by all pools (variable, decreasing as rewards are allocated until 0)
    uint256 public rewardAmountRemaining;
    // Number of Ads awarded per block
    uint256 public adPerBlock;
    // Total allocation of POITNs. Must be the sum of all allocated points in all pools.
    uint256 public totalAllocPoint = 0;
    //The default base of the unlock multiple is 1
    uint public unlockMultiple;

    uint256 public stakingThreshold;//Pledge the AD threshold. LP can be pledged only when the threshold is exceeded
    uint256 public stakingAmountSupply;//The Ad deposit supply pledged changes when the user pledges the Ad or withdraws

    uint public referrerRewardPercent;//Referral bonus percentage

    //pool list
    PoolInfo[] public poolInfo;
    // Information for each user that holds an LP token
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Information about each user who holds an AD reward
    mapping(address => RewardInfo) public rewardInfo;

    //events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UnlockReward(address indexed user, uint256 amount, uint256 depositAmount);
    event ExtractAD(address indexed user, uint256 amount);
    event Init(uint256 rewardAmountTotal, uint256 adPerBlock, uint256 stakingThreshold, uint unlockMultiple, uint referrerRewardPercent);
    event AddRewardAmount(uint256 amount);
    event AddPool(address indexed lpToken, uint256 allocPoint);
    event SetAllocPoint(uint256 pid, uint256 allocPoint);
    event SetUnlockMultiple(uint unlockMultiple);
    event SetAdPerBlock(uint256 adPerBlock);
    event SetStakingThreshold(uint256 stakingThreshold);
    event SetReferrerRewardPercent(uint referrerRewardPercent);

    //Constructor to pass in some contract addresses
    constructor(address _adToken) public {
        require(_adToken != address(0), "Error: address null");
        adToken = IERC20(_adToken);
    }

    //Deposit pledge: Deposit in AD or LP for AD reward
    function deposit(uint256 _pid, uint256 _amount) public {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        RewardInfo storage reward = rewardInfo[msg.sender];

        require(pool.allocPoint > 0, "Error: The bonus allocation point is 0 and cannot be pledged");

        //If LP is used, the AD saved by the user must be greater than or equal to the limit
        require(_pid != 0 ? userInfo[0][msg.sender].amount >= stakingThreshold : true, "ADPool: Wrong you must pledge enough AD to pledge LP");

        updatePool(_pid);

        require(rewardAmountRemaining > 0, "Error: Insufficient pool bonus");
        //If the user's LP token is greater than 0, the reward waiting to be issued is calculated, and if greater than 0, the reward is sent to the user
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accAdPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0 && rewardAmountRemaining > 0) {
                if (rewardAmountRemaining < pending) {
                    pending = rewardAmountRemaining;
                }
                reward.rewardTotal = reward.rewardTotal.add(pending);
                reward.rewardLocked = reward.rewardLocked.add(pending);
                rewardAmountRemaining = rewardAmountRemaining.sub(pending);

                //Give rewards to references, if they exist
                if (reward.referrer != address(0) && referrerRewardPercent > 0) {
                    RewardInfo storage referrerReward = rewardInfo[reward.referrer];
                    uint256 referrerRewardAmount = pending.mul(referrerRewardPercent).div(100);
                    if (rewardAmountRemaining < referrerRewardAmount) {
                        referrerRewardAmount = rewardAmountRemaining;
                    }
                    referrerReward.referrerRewardTotal = referrerReward.referrerRewardTotal.add(referrerRewardAmount);
                    referrerReward.rewardLocked = referrerReward.rewardLocked.add(referrerRewardAmount);
                    rewardAmountRemaining = rewardAmountRemaining.sub(referrerRewardAmount);
                }
            }
        }

        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accAdPerShare).div(1e12);

        if (_pid == 0) {//Update AD pledge amount
            stakingAmountSupply = stakingAmountSupply.add(_amount);
        }
        emit Deposit(msg.sender, _pid, _amount);
    }


    //Withdraw, withdraw pledged AD or LP
    function withdraw(uint256 _pid, uint256 _amount) public {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        RewardInfo storage reward = rewardInfo[msg.sender];

        require(user.amount >= _amount, "withdraw: not good");
        //If the AD mining pool is selected, the amount after withdrawal is less than the threshold value, it is necessary to determine whether LP is pledged, if so, the withdrawal cannot be made
        if (_pid == 0 && user.amount.sub(_amount) < stakingThreshold) {
            require(!isHasDepositLP(msg.sender), "Error: you still have LP under pledge, can't take so much AD");
        }
        updatePool(_pid);
        //        Send rewards, if they exist
        uint256 pending = user.amount.mul(pool.accAdPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0 && rewardAmountRemaining > 0) {
            if (rewardAmountRemaining < pending) {
                pending = rewardAmountRemaining;
            }
            reward.rewardTotal = reward.rewardTotal.add(pending);
            reward.rewardLocked = reward.rewardLocked.add(pending);
            rewardAmountRemaining = rewardAmountRemaining.sub(pending);

            //Give rewards to references, if they exist
            if (reward.referrer != address(0) && referrerRewardPercent > 0) {
                RewardInfo storage referrerReward = rewardInfo[reward.referrer];
                uint256 referrerRewardAmount = pending.mul(referrerRewardPercent).div(100);
                if (rewardAmountRemaining < referrerRewardAmount) {
                    referrerRewardAmount = rewardAmountRemaining;
                }
                referrerReward.referrerRewardTotal = referrerReward.referrerRewardTotal.add(referrerRewardAmount);
                referrerReward.rewardLocked = referrerReward.rewardLocked.add(referrerRewardAmount);
                rewardAmountRemaining = rewardAmountRemaining.sub(referrerRewardAmount);
            }
        }
        user.amount = user.amount.sub(_amount);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        user.rewardDebt = user.amount.mul(pool.accAdPerShare).div(1e12);

        if (_pid == 0) {//Update AD pledge amount
            stakingAmountSupply = stakingAmountSupply.sub(_amount);
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }

    //Determine whether the user has pledged any LP pool
    function isHasDepositLP(address _user) public view returns (bool){
        for (uint i = 1; i < poolInfo.length; i++) {
            if (userInfo[i][_user].amount > 0) {
                return true;
            }
        }
        return false;
    }

    //Set the recommender. If the recommender has been set, it cannot be changed
    function setReferrer(address _referrer) public {
        require(_referrer != address(0) && _referrer != address(msg.sender), "Error: Referrer address cannot be empty or own");
        RewardInfo storage reward = rewardInfo[msg.sender];
        require(reward.referrer == address(0), "Error: References have been set");
        reward.referrer = _referrer;
        RewardInfo storage referrerReward = rewardInfo[_referrer];
        referrerReward.referrals.push(address(msg.sender));
    }


    //unlockReward
    function unlockReward(uint256 _amount, uint256 _depositAmount) public {

        RewardInfo storage reward = rewardInfo[msg.sender];
        require(_amount > 0 && reward.rewardLocked >= _amount, "Error: Insufficient reward AD amount in lock");

        uint multiple = _depositAmount / _amount;
        require(multiple >= 1, "Error: The AD unlock multiple is less than 1");

        adToken.safeTransferFrom(address(msg.sender), address(this), _depositAmount);

        reward.rewardUnlocks.push(
            RewardUnlock({
        rewardAmount : _amount,
        depositAmount : _depositAmount,
        startTime : block.timestamp,
        endTime : block.timestamp + (multiple >= 1 * unlockMultiple && multiple < 2 * unlockMultiple ? 5 days : multiple >= 2 * unlockMultiple && multiple < 3 * unlockMultiple ? 4 days : multiple >= 3 * unlockMultiple && multiple < 4 * unlockMultiple ? 3 days : multiple >= 4 * unlockMultiple && multiple < 5 * unlockMultiple ? 2 days : 1 days),
        totalAmount : _amount.add(_depositAmount),
        extractTotalAmount : _amount.add(_depositAmount)
        })
        );

        reward.rewardLocked = reward.rewardLocked.sub(_amount);

        emit UnlockReward(msg.sender, _amount, _depositAmount);
    }


    // Obtain AD amount to be withdrawn (unlocked reward + AD deposit for unlocking)
    function getPendingExtractAD(address _user) public view returns (uint256){
        uint256 amount = 0;
        RewardInfo storage reward = rewardInfo[_user];
        for (uint i = 0; i < reward.rewardUnlocks.length; i++) {
            if (block.timestamp >= reward.rewardUnlocks[i].endTime && reward.rewardUnlocks[i].extractTotalAmount > 0) {
                amount = amount.add(reward.rewardUnlocks[i].extractTotalAmount);
            }
        }
        return amount;
    }

    //Get the length of the list of people I recommend
    function getReferralsLength(address _user) public view returns (uint256){
        return rewardInfo[_user].referrals.length;
    }

    //Get the people I recommend
    function getReferrals(address _user, uint256 _index) public view returns (address){
        return rewardInfo[_user].referrals[_index];
    }

    //Gets the length of the reward unlock list
    function getRewardUnlockLength(address _user) public view returns (uint256){
        return rewardInfo[_user].rewardUnlocks.length;
    }

    //Get the reward unlock list
    function getRewardUnlock(address _user, uint256 _index) public view returns (RewardUnlock memory){
        return rewardInfo[_user].rewardUnlocks[_index];
    }

    //AD withdrawal (withdrawal from unlocked, including AD deposits used to unlock)
    function extractAD(uint256 _amount) public {

        require(getPendingExtractAD(msg.sender) >= _amount, "Error: Insufficient extractable AD");

        RewardInfo storage reward = rewardInfo[msg.sender];
        uint256 tempAmount = _amount;

        for (uint i = 0; i < reward.rewardUnlocks.length; i++) {
            if (block.timestamp >= reward.rewardUnlocks[i].endTime && reward.rewardUnlocks[i].extractTotalAmount > 0) {

                //The amount of the unlock list is sufficient
                if (reward.rewardUnlocks[i].extractTotalAmount >= tempAmount) {
                    reward.rewardUnlocks[i].extractTotalAmount = reward.rewardUnlocks[i].extractTotalAmount.sub(tempAmount);
                    break;
                } else {
                    //Not enough, but minus
                    tempAmount = tempAmount.sub(reward.rewardUnlocks[i].extractTotalAmount);
                    reward.rewardUnlocks[i].extractTotalAmount = 0;
                }
            }
        }
        safeAdTransfer(msg.sender, _amount);

        emit ExtractAD(msg.sender, _amount);
    }

    //Query the user for pending rewards
    function pendingReward(uint256 _pid, address _user) external view returns (uint256){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAdPerShare = pool.accAdPerShare;
        uint256 lpSupply = _pid == 0 ? stakingAmountSupply : pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 adReward = block.number.sub(pool.lastRewardBlock).mul(adPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accAdPerShare = accAdPerShare.add(adReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accAdPerShare).div(1e12).sub(user.rewardDebt);
    }

    //pool Length
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    //Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = _pid == 0 ? stakingAmountSupply : pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        if (rewardAmountRemaining <= 0) {
            return;
        }

        uint256 adReward = block.number.sub(pool.lastRewardBlock).mul(adPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accAdPerShare = pool.accAdPerShare.add(adReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    //Initialize the
    function init(uint256 _rewardAmountTotal, uint256 _adPerBlock, uint256 _stakingThreshold, uint _unlockMultiple, uint _referrerRewardPercent) public onlyOwner {

        require(rewardAmountTotal == 0, "Error: Do not repeat the initial contract");

        require(_rewardAmountTotal > 0 && _adPerBlock > 0 && _stakingThreshold > 0 && _unlockMultiple > 0 && _referrerRewardPercent > 0, "Error: Parameter is not correct");

        adToken.safeTransferFrom(address(msg.sender), address(this), _rewardAmountTotal);

        rewardAmountTotal = _rewardAmountTotal;
        rewardAmountRemaining = _rewardAmountTotal;
        adPerBlock = _adPerBlock;

        stakingThreshold = _stakingThreshold;
        unlockMultiple = _unlockMultiple;
        referrerRewardPercent = _referrerRewardPercent;

        // staking pool
        addPool(adToken, 0, false);

        emit Init(_rewardAmountTotal, _adPerBlock, _stakingThreshold, _unlockMultiple, _referrerRewardPercent);
    }

    //Add mine pool bonus, be sure to approve enough AD amount before adding
    function addRewardAmount(uint256 _amount) public onlyOwner {
        adToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        rewardAmountTotal = rewardAmountTotal.add(_amount);
        rewardAmountRemaining = rewardAmountRemaining.add(_amount);

        emit AddRewardAmount(_amount);
    }

    //Add a new LP mining pool to the pool, which can only be called by the holder
    // Don't add the same LP token repeatedly if you do, the reward will be scrambled
    function addPool(IERC20 _lpToken, uint256 _allocPoint, bool _withUpdate) public onlyOwner {

        if (_withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(
            PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : block.number,
        accAdPerShare : 0
        })
        );

        emit AddPool(address(_lpToken), _allocPoint);
    }

    //Sets the AD allocation point for the specified pool
    function setAllocPoint(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;

        emit SetAllocPoint(_pid, _allocPoint);
    }

    //Set unlock deposit multiple
    function setUnlockMultiple(uint _unlockMultiple) public onlyOwner {
        unlockMultiple = _unlockMultiple;

        emit SetUnlockMultiple(_unlockMultiple);
    }

    //Set the mining amount of each block
    function setAdPerBlock(uint256 _adPerBlock, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        adPerBlock = _adPerBlock;

        emit SetAdPerBlock(_adPerBlock);
    }

    //Set AD pledge amount limit
    function setStakingThreshold(uint256 _stakingThreshold) public onlyOwner {
        stakingThreshold = _stakingThreshold;

        emit SetStakingThreshold(_stakingThreshold);
    }

    //Set a percentage of the referrer's reward
    function setReferrerRewardPercent(uint _referrerRewardPercent) public onlyOwner {
        referrerRewardPercent = _referrerRewardPercent;

        emit SetReferrerRewardPercent(_referrerRewardPercent);
    }

    // Secure AD transfer in case there is not enough AD in the pool due to rounding errors.
    function safeAdTransfer(address _to, uint256 _amount) internal {
        uint256 adBal = adToken.balanceOf(address(this));
        if (_amount > adBal) {
            adToken.transfer(_to, adBal);
        } else {
            adToken.transfer(_to, _amount);
        }
    }

}
