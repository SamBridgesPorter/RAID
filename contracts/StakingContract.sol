pragma solidity >=0.7.0 <=0.8.0;
// this contract is such a mess, if we want founders and liquidity providers have different rewards rate, while having different variables for tokenAmount
// can't just add a bonus modifier for founders, because that's how founders can compound that bonus, and liquidity mining can become way more
// centralized than we can afford
// i wrote full functionality first, but the code was looking too ugly
// i almost want to change the entire system only to make the code look more or less nice
// did change it a small bit: founders are unable to stake generic liquidity on top of their share, or it will be too expensive to sload
// for that they will have to use another address
// the code still looks ugly, not sure what can i do, but i will try

import "./IUniswapV2Pair.sol";
import "./ITreasury.sol";
import "./IERC20.sol";
import "./IGovernance.sol";
import "./IBridge.sol";

contract StakingContract {
	uint128 private _foundingETHDeposited;
	uint128 private _foundingLPtokensMinted;
	uint private _foundingTokenAmount;
	uint private _genTotTokenAmount;
	address private _tokenETHLP; // create2 and hardcode too?
	bool private _notInit;
///////variables for testing purposes
	address private _token; // hardcoded address
	address private _treasury; // hardcoded
	address private _governance; // hardcoded
	address private _founding;// hardcoded

//////
	constructor() {
		_token = 0xf8e81D47203A594245E36C48e151709F0C19fBe8; // testing
		_foundingTokenAmount = 1e27;
		_notInit = true;
	}

	function init(uint foundingETH, address tkn) public {
		require(msg.sender == _founding && _notInit == true);
		delete _notInit;
		_foundingETHDeposited = uint128(foundingETH);
		_foundingLPtokensMinted = uint128(IERC20(tkn).balanceOf(address(this)));
		_tokenETHLP = tkn;
	}

	struct Provider {uint96 lastClaim; uint128 tokenAmount; bool founder; uint128 lpShare;uint128 lockedAmount;uint128 lockUpTo;}
	struct Locker {uint128 amount;uint128 lockUpTo;}

	mapping(address => Provider) private _ps;
	mapping(address => Locker) private _ls;
	mapping(address => uint) private _locks;
	mapping(address => address) public newAddresses;
	mapping(address => address) private _linked;
	mapping(address => bool) private _taken;

	event AddressLinked(address indexed address1, address indexed address2);

	modifier lock() {require(block.number>_locks[msg.sender]);_locks[msg.sender] = block.number + 1;_;}

	function claimFounderStatus() public {
		uint ethContributed = IFoundingEvent(_founding).contributions(msg.sender);
		require(ethContributed > 0);
		require(_notInit == false && _ps[msg.sender].founder == false);
		_ps[msg.sender].founder = true;
		uint foundingETH = _foundingETHDeposited;
		uint lpShare = _foundingLPtokensMinted*ethContributed/foundingETH;
		uint tokenAmount = ethContributed*1e27/foundingETH;
		_ps[msg.sender].lpShare = uint128(lpShare);
		_ps[msg.sender].tokenAmount = uint128(tokenAmount);
		_ps[msg.sender].lastClaim = uint96(block.number);//hardcoded genesis block
	}

	function unstakeLp(bool ok,uint amount) public lock {
		uint lpShare = _ps[msg.sender].lpShare;
		uint lockedAmount = _ps[msg.sender].lockedAmount;
		uint percent = amount*100;
		require(lpShare-lockedAmount >= amount);
		_ps[msg.sender].lpShare = uint128(lpShare - amount);
		percent = percent/lpShare;
		uint tknAmount = _ps[msg.sender].tokenAmount;
		uint toSubtract = tknAmount*percent/100; // not an array of deposits. if a provider stakes and then stakes again, and then unstakes - he loses share as if he staked only once at lowest price he had
		_ps[msg.sender].tokenAmount -= uint128(toSubtract);
		if (_ps[msg.sender].founder == true) {_foundingTokenAmount -= toSubtract;}else{_genTotTokenAmount -= toSubtract;}
		IERC20(_tokenETHLP).transfer(address(msg.sender), amount);
	}

	function getRewards() public {
		uint lastClaim = _ps[msg.sender].lastClaim;
		require(block.number>lastClaim*10);
		_ps[msg.sender].lastClaim = uint96(block.number/10);
		uint halver = block.number/10000000;
		uint rate = 21e18;if (halver>1) {for (uint i=1;i<halver;i++) {rate=rate*5/6;}}
		uint toClaim =(block.number - lastClaim)*_ps[msg.sender].tokenAmount;
		if (_ps[msg.sender].founder == true) {toClaim = toClaim*rate/_foundingTokenAmount;} else {rate = rate*2/3;toClaim = toClaim*rate/_genTotTokenAmount;}
		bool success = ITreasury(_treasury).getRewards(msg.sender, toClaim);
		require(success == true);
	}

// this function has to be expensive as an alert of something fishy just in case
// metamask has to somehow provide more info about a transaction
	function newAddress(address a) public {
		if(_ps[msg.sender].lockedAmount>0||_ls[msg.sender].amount>0){require(_isContract(msg.sender) == false);}
		for (uint i = 0;i<10;i++) {delete newAddresses[msg.sender];newAddresses[msg.sender] = a;}
	}
// nobody should trust dapp interface. maybe a function like this should not be provided through dapp at all
	function changeAddress(address ad) public lock { // while user can confirm newAddress by public method, still has to enter the same address second time
		address S = msg.sender;
		address a = newAddresses[S];
		require(a != address(0) && a == ad && block.number + 172800 > IGovernance(_governance).getLastVoted(S));
		if (_ps[S].lpShare >0) {
			_ps[a].lpShare = _ps[S].lpShare;_ps[a].tokenAmount = _ps[S].tokenAmount;_ps[a].lastClaim = _ps[S].lastClaim;_ps[a].lockUpTo = _ps[S].lockUpTo;
			_ps[a].lockedAmount = _ps[S].lockedAmount;_ps[a].founder = _ps[S].founder;delete _ps[S];
		}
		if (_ls[S].amount > 0) {_ls[a].amount=_ls[S].amount;_ls[a].lockUpTo=_ls[S].lockUpTo;delete _ls[S];}
		IGovernance(_governance).changeAddress(S,a);
	}

	function lockFor3Years(bool ok, address tkn, uint amount) public {
		require(ok==true && amount>0 && _isContract(msg.sender) == false);
		if(tkn ==_tokenETHLP) {
			require(_ps[msg.sender].lpShare-_ps[msg.sender].lockedAmount>=amount); _ps[msg.sender].lockUpTo=uint128(block.number+6307200);_ps[msg.sender].lockedAmount+=uint128(amount);	
		}
		if(tkn == _token) {
			require(IERC20(tkn).balanceOf(msg.sender)>=amount);
			_ls[msg.sender].lockUpTo=uint128(block.number+6307200);
			_ls[msg.sender].amount+=uint128(amount);
			IERC20(tkn).transferFrom(msg.sender,address(this),amount);
		}
	}

	function unlock() public lock {
		if (_ps[msg.sender].lockedAmount > 0 && block.number>=_ps[msg.sender].lockUpTo) {_ps[msg.sender].lockedAmount = 0;}
		uint amount = _ls[msg.sender].amount;
		if (amount > 0 && block.number>=_ls[msg.sender].lockUpTo) {IERC20(_token).transfer(msg.sender,amount);_ls[msg.sender].amount = 0;}
	}

	function stake(uint amount) public {
		address tkn = _tokenETHLP;
		require(_ps[msg.sender].founder==false && IERC20(tkn).balanceOf(msg.sender)>=amount);
		if (_ps[msg.sender].lastClaim == 0) {_ps[msg.sender].lastClaim = uint96(block.number);} else{require(block.number < _ps[msg.sender].lastClaim+100);}
		_genTotTokenAmount += amount;
		(uint res0,uint res1,)=IUniswapV2Pair(tkn).getReserves();
		uint total = IERC20(tkn).totalSupply();
		uint share;
		if (res0 > res1) {share = res0*amount/total;} else {share = res1*amount/total;}
		_ps[msg.sender].tokenAmount += uint128(share);
		IERC20(tkn).transferFrom(msg.sender,address(this),amount);
	}
 
	function migrate(address contr,address tkn,uint amount) public lock {//can support any amount of bridges
		if (tkn == _tokenETHLP) {
			uint lpShare = _ps[msg.sender].lpShare;
			uint lockedAmount = _ps[msg.sender].lockedAmount;
			require(lpShare-lockedAmount >= amount);
			_ps[msg.sender].lpShare = uint128(lpShare - amount);
			uint percent = amount*100/lpShare;
			uint128 tknA = _ps[msg.sender].tokenAmount;
			uint toSubtract = tknA*percent/100;
			_ps[msg.sender].tokenAmount = tknA - uint128(toSubtract);
			bool status = _ps[msg.sender].founder;
			if (status == true){_foundingTokenAmount -= toSubtract;} else{_genTotTokenAmount -= toSubtract;}
			IERC20(tkn).transfer(contr, amount);
			IBridge(contr).provider(msg.sender,amount,_ps[msg.sender].lastClaim,toSubtract,status);
		}
		if (tkn == _token) {
			uint lockedAmount = _ls[msg.sender].amount;
			require(lockedAmount >= amount);
			IERC20(tkn).transfer(contr, amount);
			_ls[msg.sender].amount = uint128(lockedAmount-amount);
			IBridge(contr).locker(msg.sender,amount,_ls[msg.sender].lockUpTo);
		}
	}

	function linkAddress(address a) external { // can be used to limit the amount of testers to only approved addresses
		require(_linked[msg.sender] != a && _taken[a] == false && _isFounder(a) == false);_linked[msg.sender] = a;_linked[a] = msg.sender;_taken[a] = true;emit AddressLinked(msg.sender,a);
	}
// VIEW FUNCTIONS ==================================================
	function getProvider(address a) external view returns (uint lpShare, uint lastClaim, address linked) {return (_ps[a].lpShare,_ps[a].lastClaim,_linked[a]);}
	function getTknAmntLckPt(address a) external view returns (uint tknAmount,uint lockUpTo) {return (_ps[a].tokenAmount,_ps[a].lockUpTo);}
	function _isFounder(address a) internal view returns(bool) {if (IFoundingEvent(_founding).contributions(a) > 0) {return true;} else {return false;}}
	function _isContract(address a) internal view returns(bool) {uint256 size;assembly {size := extcodesize(a)}return size > 0;}
}