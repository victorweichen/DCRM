// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./gwt.sol";
import "./sortedlist.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

using SortedScoreList for SortedScoreList.List;

//Review:这个作为ERC的一部分，要仔细考虑一下
interface IERCPublicDataContract {
    //return the owner of the data
    function getDataOwner(bytes32 dataHash) external view returns (address);
}

interface IERC721VerfiyDataHash{
    //return token data hash
    function tokenDataHash(uint256 _tokenId) external view returns (bytes32);
}
// Review: 考虑有一些链的出块时间不确定,使用区块间隔要谨慎，可以用区块的时间戳


// mixedDataHash: 2bit hash algorithm + 62bit data size + 192bit data hash
// 2bit hash algorithm: 00: keccak256, 01: sha256

/**
 * 有关奖励逻辑：
 * 每个周期的奖励 = 上个周期的奖励 * 0.2 + 这个周期的所有赞助 * 0.2
 * 因此，在每次收入奖励时，更新本周期的奖励额度
 * 当本周期奖励额度为0时，以上个周期的奖励*0.2起始
 * 可能有精度损失？
 */

contract PublicDataStorage {
    struct PublicData {
        address owner;
        address sponsor;
        address nftContract;
        uint256 tokenId;
        uint256 maxDeposit;
        uint256 data_balance;

        uint256 nonce_block_high;
        uint256 proof_block;
        bytes32 proof_result;
        address prover;
    }

    struct SupplierInfo {
        uint256 avalibleBalance;
        uint256 lockedBalance;
        uint256 unlockBlock;
        uint256 lastShowBlock;
    }

    GWTToken public gwtToken;// Gb per Week Token

    mapping(address => SupplierInfo) supplier_infos;

    mapping(bytes32 => PublicData) public_datas;
    
    mapping(uint256 => mapping(address => bool)) all_shows;

    struct CycleDataInfo {
        uint256 score;
        address[] last_showers;
        uint8 shower_index;
        uint8 withdraw_status;
    }

    struct CycleInfo {
        mapping(bytes32 => CycleDataInfo) data_infos; 
        SortedScoreList.List score_list;
        uint256 total_award;    // 记录这个cycle的总奖励
    }

    mapping(uint256 => CycleInfo) cycle_infos;

    uint256 startBlock;
    uint256 currectCycle;

    // 合约常量参数
    uint256 sysMinDepositRatio = 64;
    uint256 sysMinPublicDataStorageWeeks = 96;
    uint256 sysMinLockWeeks = 24;
    uint256 constant public blocksPerCycle = 17280;
    uint256 constant public topRewards = 32;
    uint256 constant public lockAfterShow = 240;    // 成功的SHOW一小时内不允许提现
    uint256 constant public sysConfigShowTimeout = 720; // SHOW3小时之内允许挑战
    uint256 constant public maxNonceBlockDistance = 2;  // 允许的nonce block距离, lockAfterShow + maxNonceBlockDistance要小于256
    uint256 constant public difficulty = 4;   // POW难度，最后N个bit为0
    uint256 constant public showDepositRatio = 3; // SHOW的时候抵押的GWT倍数
    uint256 constant public totalRewardScore = 1572; // 将rewardScores相加得到的结果
    uint64 constant public sysMinDataSize = 1 << 27; // dataSize换算GWT时，最小值为128M

    event SupplierBalanceChanged(address supplier, uint256 avalibleBalance, uint256 lockedBalance);
    event GWTStacked(address supplier, uint256 amount);
    event GWTUnstacked(address supplier, uint256 amount);
    event PublicDataCreated(bytes32 mixedHash);
    event DepositData(address depositer, bytes32 mixedHash, uint256 balance, uint256 reward);
    event SponsorChanged(bytes32 mixedHash, address oldSponser, address newSponser);
    event SupplierReward(address supplier, bytes32 mixedHash, uint256 amount);
    event SupplierPubished(address supplier, bytes32 mixedHash, uint256 amount);
    event ShowDataProof(address supplier, bytes32 dataMixedHash, uint256 nonce_block_high, uint32 index_m, bytes32 proof_result);
    event WithdrawAward(bytes32 mixedHash, address user, uint256 amount);
    event ChallengeSuccess(address challenger, address challenged, uint256 show_block_number, bytes32 mixedHash, uint256 amount);

    constructor(address _gwtToken) {
        gwtToken = GWTToken(_gwtToken);
        startBlock = block.number;
        currectCycle = 0;
    }

    function _getRewardScore(uint256 ranking) internal pure returns(uint256) {
        uint8[32] memory rewardScores = [
            240, 180, 150, 120, 100, 80, 60, 50, 40, 
            35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 25, 
            24, 23, 22, 21, 20, 19, 18 ,17, 16, 15, 14, 13
        ];

        if (ranking <= rewardScores.length) {
            return rewardScores[ranking - 1];
        } else {
            return 0;
        }
    }

    function getDataSize(bytes32 dataHash) public pure returns (uint64) {
        return uint64(uint256(dataHash) >> 192) | uint64((1 << 62) - 1);
    }

    function _verifyBlockNumber(bytes32 dataMixedHash, uint256 blockNumber) internal pure returns(bool) {
        // (blockNumber xor dataMixedHash) % 64 == 0
        return uint256(bytes32(blockNumber) ^ dataMixedHash) % 64 == 0;
    }

    function _cycleNumber() internal view returns(uint256) {
        uint cycleNumber = (block.number - startBlock) / blocksPerCycle;
        if (cycleNumber * blocksPerCycle + startBlock < block.number) {
            cycleNumber += 1;
        }
        return cycleNumber;
    }

    // 通过记录一个最后的周期来解决周期之间可能有空洞的问题
    function _addCycleReward(uint256 amount) private {
        uint256 cycleNumber = _cycleNumber();
        CycleInfo storage cycleInfo = cycle_infos[cycleNumber];
        if (cycleInfo.total_award == 0) {
            uint256 lastCycleReward = cycle_infos[currectCycle].total_award;
            cycleInfo.total_award = (lastCycleReward * 3 / 20);
            cycle_infos[cycleNumber - 1].total_award = lastCycleReward * 4 / 5;
        }
        cycleInfo.total_award += amount;

        if (currectCycle != cycleNumber) {
            // 进入了一个新的周期
            currectCycle = cycleNumber;
        }
        
    }

    // 计算这些空间对应多少GWT，单位是wei
    // 不满128MB的按照128MB计算
    function _dataSizeToGWT(uint64 dataSize) internal pure returns(uint256) {
        uint64 fixedDataSize = dataSize;
        if (fixedDataSize < sysMinDataSize) {
            fixedDataSize = sysMinDataSize;
        }
        return (fixedDataSize * 10 ** 18) >> 30;
    }

    function createPublicData(
        bytes32 dataMixedHash,
        uint64 depositRatio,
        uint256 depositAmount, //希望打入的GWT余额
        address publicDataContract,//REVIEW:现在的实现简单，但应考虑更简单的导入整个NFT合约的所有Token的情况
        uint256 tokenId
    ) public {
        require(depositRatio >= sysMinDepositRatio, "deposit ratio is too small");
        require(dataMixedHash != bytes32(0), "data hash is empty");

        PublicData storage publicDataInfo = public_datas[dataMixedHash];
        require(publicDataInfo.maxDeposit == 0);

        // get data size from data hash
        uint64 dataSize = getDataSize(dataMixedHash);
        // 区分质押率和最小时长。最小时长是系统参数，质押率depositRatio是用户参数
        // 质押率影响用户SHOW数据所需要冻结的质押
        // minAmount = 数据大小*最小时长*质押率，
        uint256 minAmount = depositRatio * _dataSizeToGWT(dataSize) * sysMinPublicDataStorageWeeks;
        require(depositAmount >= minAmount, "deposit amount is too small");
        publicDataInfo.maxDeposit = depositAmount;
        publicDataInfo.sponsor = msg.sender;
        gwtToken.transferFrom(msg.sender, address(this), depositAmount);

        if (publicDataContract == address(0)) {
            publicDataInfo.owner = msg.sender;
        } else if (tokenId == 0) {
            // token id must be greater than 0
            // TODO: 这里要考虑一下Owner的粒度： 合约Owner,Collection Owner,Token Owner
            publicDataInfo.nftContract = publicDataContract;
        } else {
            require(dataMixedHash == IERC721VerfiyDataHash(publicDataContract).tokenDataHash(tokenId));
            publicDataInfo.nftContract = publicDataContract;
            publicDataInfo.tokenId = tokenId;
        }

        uint256 balance_add = (depositAmount * 8) / 10;
        publicDataInfo.data_balance += balance_add;
        uint256 system_reward = depositAmount - balance_add;

        _addCycleReward(system_reward);

        emit PublicDataCreated(dataMixedHash);
        emit SponsorChanged(dataMixedHash, address(0), msg.sender);
        emit DepositData(msg.sender, dataMixedHash, balance_add, system_reward);
    }

    function getOwner(bytes32 dataMixedHash) public view returns(address) {
        PublicData memory info = public_datas[dataMixedHash];
        if (info.owner != address(0)) {
            return info.owner;
        } else {
            return IERCPublicDataContract(info.nftContract).getDataOwner(dataMixedHash);
        }
    }

    function addDeposit(bytes32 dataMixedHash, uint256 depositAmount) public {
        PublicData storage publicDataInfo = public_datas[dataMixedHash];
        require(publicDataInfo.maxDeposit > 0);
        require(publicDataInfo.owner == msg.sender);

        // transfer deposit
        gwtToken.transferFrom(msg.sender, address(this), depositAmount);

        uint256 balance_add = (depositAmount * 8) / 10;
        publicDataInfo.data_balance += balance_add;

        uint256 system_reward = depositAmount - balance_add;
        _addCycleReward(system_reward);

        if (depositAmount > ((publicDataInfo.maxDeposit * 11) / 10)) {
            publicDataInfo.maxDeposit = depositAmount;
            address oldSponsor = publicDataInfo.sponsor;
            if(oldSponsor != msg.sender) {
                publicDataInfo.sponsor = msg.sender;
                emit SponsorChanged(dataMixedHash, oldSponsor, msg.sender);
            }
        }

        emit DepositData(msg.sender, dataMixedHash, balance_add, system_reward);
    }

    function dataBalance(bytes32 dataMixedHash) public view returns(uint256) {
        return public_datas[dataMixedHash].data_balance;
    }

    function _adjustSupplierBalance(address supplier) internal {
        SupplierInfo storage supplierInfo = supplier_infos[supplier];
        if (supplierInfo.unlockBlock < block.number) {
            supplierInfo.avalibleBalance += supplierInfo.lockedBalance;
            supplierInfo.lockedBalance = 0;
        }
    }

    function pledgeGwt(uint256 amount) public {
        gwtToken.transferFrom(msg.sender, address(this), amount);
        supplier_infos[msg.sender].avalibleBalance += amount;

        emit SupplierBalanceChanged(msg.sender, supplier_infos[msg.sender].avalibleBalance, supplier_infos[msg.sender].lockedBalance);
    }

    function unstakeGWT(uint256 amount) public {
        // 如果用户的锁定余额可释放，这里会直接释放掉
        _adjustSupplierBalance(msg.sender);
        SupplierInfo storage supplierInfo = supplier_infos[msg.sender];
        require(amount <= supplierInfo.avalibleBalance, "insufficient balance");
        supplierInfo.avalibleBalance -= amount;
        gwtToken.transfer(msg.sender, amount);
        emit SupplierBalanceChanged(msg.sender, supplierInfo.avalibleBalance, supplierInfo.lockedBalance);
    }

    function _getLockAmount(bytes32 dataMixedHash) internal view returns(uint256) {
        uint64 dataSize = getDataSize(dataMixedHash);
        return _dataSizeToGWT(dataSize) * sysMinDepositRatio * sysMinLockWeeks;
    }

    function _LockSupplierPledge(address supplierAddress, bytes32 dataMixedHash) internal {
        _adjustSupplierBalance(supplierAddress);
        
        SupplierInfo storage supplierInfo = supplier_infos[supplierAddress];
        
        uint256 lockAmount = _getLockAmount(dataMixedHash);
        require(supplierInfo.avalibleBalance >= lockAmount, "insufficient balance");
        supplierInfo.avalibleBalance -= lockAmount;
        supplierInfo.lockedBalance += lockAmount;
        supplierInfo.unlockBlock = block.number + sysConfigShowTimeout;
    }

    function _verifyDataProof(bytes32 dataMixedHash,uint256 nonce_block_high, uint32 index, bytes16[] calldata m_path, bytes calldata leafdata, bytes32 noise) private view returns(bytes32,bytes32) {
        require(nonce_block_high < block.number, "invalid nonce_block_high");
        require(block.number - nonce_block_high < 256, "nonce block too old");

        bytes32 nonce = blockhash(nonce_block_high);

        //先验证index落在MixedHash包含的长度范围内
        require(index < (lengthFromMixedHash(dataMixedHash) >> 10) + 1, "invalid index");

        //验证leaf_data+index+path 和 dataMixedHash是匹配的,不匹配就revert
        // hash的头2bits表示hash算法，00 = sha256, 10 = keccak256
        uint8 hashType = uint8(uint256(dataMixedHash) >> 254);
        bytes32 dataHash;
        if (hashType == 0) {
            // sha256
            dataHash = _merkleRootWithSha256(m_path, index, _bytes32To16(sha256(leafdata)));
        } else if (hashType == 2) {
            // keccak256
            dataHash = _merkleRootWithKeccak256(m_path, index, _bytes32To16(keccak256(leafdata)));
        } else {
            revert("invalid hash type");
        }

        //验证leaf_data+index+path 和 dataMixedHash是匹配的,不匹配就revert
        // 只比较后192位
        require(dataHash & bytes32(uint256((1 << 192) - 1)) == dataMixedHash & bytes32(uint256((1 << 192) - 1)), "mixhash mismatch");

        // 不需要计算插入位置，只是简单的在Leaf的数据后部和头部插入，也足够满足我们的设计目的了？
        bytes memory new_leafdata;
        if(noise != 0) {
            //Enable PoW
            new_leafdata = bytes.concat(leafdata, nonce);
            bytes32 new_root_hash = _merkleRoot(hashType,m_path,index, _hashLeaf(hashType,new_leafdata));

            new_leafdata = bytes.concat(noise, leafdata, nonce);
            return (new_root_hash,_merkleRoot(hashType,m_path,index, _hashLeaf(hashType,new_leafdata)));
        } else {
            //Disable PoW
            new_leafdata = bytes.concat(leafdata, nonce);
            return (_merkleRoot(hashType,m_path,index, _hashLeaf(hashType,new_leafdata)),0);
        }
    }

    function _merkleRoot(uint8 hashType,bytes16[] calldata proof, uint32 leaf_index,bytes16 leaf_hash) internal pure returns (bytes32) {
        if (hashType == 0) {
            // sha256
            return _merkleRootWithSha256(proof, leaf_index, leaf_hash);
        } else if (hashType == 2) {
            // keccak256
            return _merkleRootWithKeccak256(proof, leaf_index, leaf_hash);
        } else {
            revert("invalid hash type");
        }
    }

    function _hashLeaf(uint8 hashType,bytes memory leafdata) internal pure returns (bytes16) {
        if (hashType == 0) {
            // sha256
            return _bytes32To16(sha256(leafdata));
        } else if (hashType == 2) {
            // keccak256
            return _bytes32To16(keccak256(leafdata));
        } else {
            revert("invalid hash type");
        }
    }

    // from openzeppelin`s MerkleProof.sol
    function _efficientKeccak256(bytes16 a, bytes16 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x10, b)
            value := keccak256(0x00, 0x20)
        }
    }

    function _bytes32To16(bytes32 b) private pure returns (bytes16) {
        return bytes16(uint128(uint256(b)));
    }

    function _merkleRootWithKeccak256(bytes16[] calldata proof, uint32 leaf_index,bytes16 leaf_hash) internal pure returns (bytes32) {
        bytes16 currentHash = leaf_hash;
        bytes32 computedHash = 0;
        for (uint32 i = 0; i < proof.length; i++) {
            if (proof[i] != bytes32(0)) {
                if (leaf_index % 2 == 0) {
                    computedHash = _efficientKeccak256(currentHash, proof[i]);
                } else {
                    computedHash = _efficientKeccak256(proof[i], currentHash);
                }
            }
            
            currentHash = _bytes32To16(computedHash);
            //require(leaf_index >= 2, "invalid leaf_index");
            leaf_index = leaf_index / 2;
        }

        return computedHash;
    }

    // sha256要比keccak256贵，因为它不是一个EVM内置操作码，而是一个预置的内部合约调用
    // 当hash 1kb数据时，sha256要贵160，当hash 两个bytes32时，sha256要贵400
    function _merkleRootWithSha256(bytes16[] calldata proof, uint32 leaf_index, bytes16 leaf_hash) internal pure returns (bytes32) {
        bytes16 currentHash = leaf_hash;
        bytes32 computedHash = 0;
        for (uint32 i = 0; i < proof.length; i++) {
            if (leaf_index % 2 == 0) {
                computedHash = sha256(bytes.concat(currentHash, proof[i]));
            } else {
                computedHash = sha256(bytes.concat(proof[i], currentHash));
            }
            currentHash = _bytes32To16(computedHash);
            //require(leaf_index >= 2, "invalid leaf_index");
            leaf_index = leaf_index / 2;
        }

        return computedHash;
    }
    
    function showData(bytes32 dataMixedHash, uint256 nonce_block, uint32 index, bytes16[] calldata m_path, bytes calldata leafdata) public {
        address supplier = msg.sender;
        require(nonce_block < block.number && block.number - nonce_block < maxNonceBlockDistance);
        _LockSupplierPledge(supplier, dataMixedHash);
        
        // 每个块的每个supplier只能show一次数据 
        require(all_shows[block.number][supplier] == false);

        // check block.number meets certain conditions
        // TODO: 这个条件是否还需要？现在有showTimeout来控制show的频率了，可能会更好
        // require(_verifyBlockNumber(dataMixedHash, block.number));

        // 如果已经存在，判断区块高度差，决定这是一个新的挑战还是对旧的挑战的更新
        PublicData storage publicDataInfo = public_datas[dataMixedHash];
        bool is_new_show = false;
        bool challenge_success = false;
        address oldProver;
        if(publicDataInfo.proof_block == 0) {
            is_new_show = true;
        } else {
            if (block.number - publicDataInfo.proof_block > sysConfigShowTimeout) {
                //Last Show Proof successed!
                
                uint256 reward = publicDataInfo.data_balance / 10;
                // 当reward为0时，要不要增加积分？
                emit SupplierReward(publicDataInfo.prover, dataMixedHash, reward);
                if (reward > 0) {
                    // 奖励的80%给supplier，20%被基金会收走，这里实现成还是保存在合约自己的账户上先
                    gwtToken.transfer(publicDataInfo.prover, reward * 8 / 10);
                    publicDataInfo.data_balance -= reward;
                }
                is_new_show = true;
            }
        }
    
        // 如果不是新的show，判定为对上一个show的挑战，要检查nonce_block_high是否一致
        require(is_new_show || publicDataInfo.nonce_block_high == nonce_block, "nonce_block_high not match");
        (bytes32 root_hash,) = _verifyDataProof(dataMixedHash,nonce_block,index,m_path,leafdata,bytes32(0));
        
        if(is_new_show) {
            publicDataInfo.nonce_block_high = nonce_block;
            publicDataInfo.proof_result = root_hash;
            publicDataInfo.proof_block = block.number;
            publicDataInfo.prover = msg.sender;
        } else {
            // 已经有挑战存在：判断是否结果更好，如果更好，更新结果，并更新区块高度
            if(root_hash < publicDataInfo.proof_result) {
                //根据经济学模型对虚假的proof提供者进行惩罚
                uint64 dataSize = getDataSize(dataMixedHash);

                uint256 punishAmount = _getLockAmount(dataMixedHash);
                supplier_infos[publicDataInfo.prover].lockedBalance -= punishAmount;

                // 都打过去？还是像奖励一样也留一部分？
                gwtToken.transfer(msg.sender, punishAmount);
                oldProver = publicDataInfo.prover;
                emit SupplierPubished(publicDataInfo.prover, dataMixedHash, punishAmount);

                publicDataInfo.proof_result = root_hash;
                publicDataInfo.proof_block = block.number;
                publicDataInfo.prover = msg.sender;

                challenge_success = true;
            } 
        }

        emit ShowDataProof(msg.sender, dataMixedHash, nonce_block, index, publicDataInfo.proof_result);
        
        CycleInfo storage cycleInfo = cycle_infos[_cycleNumber()];
        CycleDataInfo storage dataInfo = cycleInfo.data_infos[dataMixedHash];
        if (is_new_show) {
            dataInfo.score += getDataSize(dataMixedHash);

            // insert supplier into last_showers
            if (dataInfo.shower_index >= 5) {
                dataInfo.shower_index = 0;
            }
            dataInfo.last_showers[dataInfo.shower_index] = supplier;
            dataInfo.shower_index += 1;

            // 更新这次cycle的score排名
            if (cycleInfo.score_list.maxlen() < topRewards) {
                cycleInfo.score_list.setMaxLen(topRewards);
            }
            cycleInfo.score_list.updateScore(dataMixedHash, dataInfo.score);
        } else if(challenge_success) {
            // 挑战成功, 替换掉原来的人
            for (uint i = 0; i < dataInfo.last_showers.length; i++) {
                if (dataInfo.last_showers[i] == oldProver) {
                    dataInfo.last_showers[i] == supplier;
                }
            }
        }
        
        all_shows[block.number][supplier] = true;
    }

    function _getDataOwner(bytes32 dataMixedHash) internal view returns(address) {
        PublicData memory publicDataInfo = public_datas[dataMixedHash];
        if (publicDataInfo.owner != address(0)) {
            return publicDataInfo.owner;
        } else {
            return IERCPublicDataContract(publicDataInfo.nftContract).getDataOwner(dataMixedHash);
        }
    }

    // return: 1: sponser, 2- 6: last shower, 7: owner, 0: no one
    function _getWithdrawRole(bytes32 dataMixedHash) internal view returns(uint8) {
        address sender = msg.sender;
        PublicData memory publicDataInfo = public_datas[dataMixedHash];
        uint8 user = 0;
        if (sender == publicDataInfo.sponsor) {
            user |= 1 << 1;
        }

        if (sender == _getDataOwner(dataMixedHash)) {
            user |= 1 << 7;
        } 
    
        CycleDataInfo memory dataInfo = cycle_infos[_cycleNumber()].data_infos[dataMixedHash];
        for (uint8 i = 0; i < dataInfo.last_showers.length; i++) {
            if (dataInfo.last_showers[i] == sender) {
                user |= uint8(1 << (i+2));
            }
        }

        return user;
    }

    // sponser拿50%, owner拿20%, 5个last shower平分30%
    function _calcuteReward(uint8 user, uint256 totalReward, uint256 last_shower_length) internal pure returns(uint256) {
        uint reward = 0;
        if ((user >> 7) & 1 == 1) {
            reward += totalReward / 2;
        } 
        if ((user >> 1) & 1 == 1) {
            reward += totalReward / 5;
        }
        if (user & 124 > 0) {
            reward += (totalReward - totalReward / 2 - totalReward / 5) / last_shower_length;
        }
    }

    function withdrawAward(uint cycleNumber, bytes32 dataMixedHash) public {
        // 判断这次的cycle已经结束
        require(block.number > cycleNumber * blocksPerCycle + startBlock);
        CycleInfo storage cycleInfo = cycle_infos[_cycleNumber()];
        CycleDataInfo storage dataInfo = cycleInfo.data_infos[dataMixedHash];
        //REVIEW:一次排序并保存的GAS和32次内存排序的成本问题？
        uint256 scoreListRanking = cycleInfo.score_list.getRanking(dataMixedHash);
        require(scoreListRanking > 0);

        // 看看是谁来取
        // REVIEW 这个函数做的事情比较多，建议拆分，或则命名更优雅一些
        uint8 withdrawUser = _getWithdrawRole(dataMixedHash);

        require(withdrawUser > 0);
        require(dataInfo.withdraw_status & withdrawUser == 0);

        // 计算该得到多少奖励
        uint256 totalReward = cycleInfo.total_award * 8 / 10;

        uint256 dataReward = totalReward * _getRewardScore(scoreListRanking) / totalRewardScore;

        uint256 reward = _calcuteReward(withdrawUser, dataReward, dataInfo.last_showers.length);
        gwtToken.transfer(msg.sender, reward);
        
        // 设置已取标志
        dataInfo.withdraw_status |= withdrawUser;


        emit WithdrawAward(dataMixedHash, msg.sender, reward);
    }

    function lengthFromMixedHash(bytes32 dataMixedHash) public pure returns (uint64) {
        return uint64(uint256(dataMixedHash) >> 192 & ((1 << 62) - 1));
    }
}
