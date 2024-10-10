# @version ^0.3.10
# (c) Crayon Protocol Authors, 2023

"""
@title Crayon Protocol Governor
"""

from vyper.interfaces import ERC20

# TODO put bounds on fees and liquidation bonus to prevent human errors although voting process can be counted on to spot those errors
# TODO write guidelines for desk money management
# TODO for a generic sort of functionality 1) add other to proposaltype 2) implementation invokes a requires method called activate() on the address of the smart contract in the proposal?

MAX_NUM_PROPOSALS: constant(int128) = 50
MAX_NUM_DESKS: constant(int128) = 20
MAX_NUM_TOKENS: constant(int128) = 20
MAX_PROPOSAL_LENGTH: constant(int128) = 384
MAX_HORIZONS: constant(int128) = 5
VOTING_PERIOD: constant(uint256) = 40320
LOCKUP_PERIOD: constant(uint256) = 2 * VOTING_PERIOD
IMPLEMENTATION_INTERVAL: constant(uint256) = 172800
MIN_LOCKABLE: constant(uint256) = 100 * 10 ** 27
MIN_FRACTION_NUMERATOR: constant(uint256) = 20
MIN_FRACTION_DENOMINATOR: constant(uint256) = 100
MAX_DESK_PROPOSAL_ENUM: constant(uint256) = 16

interface CrayonControl:
    def is_c_control() -> bool: view
    def is_registered_desk(_desk: address) -> bool: view
    def schedule_new_fee(_horizon: uint256, _new_fee: uint256, _desk: address): nonpayable
    def schedule_new_flashloan_fee(_new_flashloan_fee: uint256, _desk: address): nonpayable
    def schedule_new_liquidation_bonus(_new_liquidation_bonus: uint256, _desk: address): nonpayable
    def set_desk_rates(_desks: DynArray[address, MAX_NUM_DESKS], _borrow_rates: DynArray[uint256, MAX_NUM_DESKS], _deposit_rates: DynArray[uint256, MAX_NUM_DESKS]): nonpayable
    def register_desk(_desk: address, _borrow_rate: uint256, _deposit_rate: uint256): nonpayable
    def unregister_desk(_desk: address): nonpayable
    def commit_new_fee(_desk: address, _horizon: uint256): nonpayable
    def commit_new_flashloan_fee(_desk: address): nonpayable
    def commit_new_liquidation_bonus(_desk: address): nonpayable
    def set_admin(_new_admin: address): nonpayable

interface CrayonTreasury:
    def add_token(_token: address): nonpayable
    def remove_token(_ind: uint256): nonpayable
    def transfer(_ind: uint256, _amount: uint256, _receiver: address): nonpayable
    def set_admin(_new_admin: address): nonpayable

interface CrayonDesk:
    def num_horizons() -> int128: view
    def get_horizon_and_fee(_ind: int128) -> (uint256, uint256): view

event CrayonProposal:
    proposal_number: indexed(uint256)
    proposal_type: indexed(ProposalType)
    desk: indexed(address)
    param1: uint256
    param2: uint256

event ProposalApproved:
    proposal_number: indexed(uint256)
    num_voters: uint256
    yes_vote: uint256
    no_vote: uint256

event ProposalRejected:
    proposal_number: indexed(uint256)
    num_voters: uint256
    yes_vote: uint256
    no_vote: uint256

event ProposalConflict:
    discarded_proposal: indexed(uint256)
    retained_proposal: indexed(uint256)

event ProposalImplemented:
    proposal_number: indexed(uint256)

struct DeskRates:
    borrow_rate: uint256
    deposit_rate: uint256

enum ProposalType:
    BorrowingFee
    FlashloanFee
    LiquidationBonus
    DeskRegistration
    DeskUnregistration # Note: last desk-related proposal. if this changes, then MAX_DESK_PROPOSAL_ENUM should be updated
    AddTreasuryToken
    RemoveTreasuryToken
    Transfer
    TreasuryAdmin
    ControlAdmin
    XcrayBlockRate
    
struct Proposal:
    is_active: bool
    is_approved: bool
    proposal_number: uint256
    proposal_type: ProposalType
    target: address
    proposer: address
    to_block: uint256
    param1: uint256
    param2: uint256
    num_voters: uint256
    yes_vote: uint256
    no_vote: uint256

struct UserVote:
    has_voted: bool
    in_favor: bool

struct UserLocked:
    xctoken_locked: uint256
    to_block: uint256

# Crayon contracts we interact with
token_contract: public(ERC20)
control_contract: public(CrayonControl)
treasury_contract: public(CrayonTreasury)

# an ever-increasing counter for numbering proposals
proposal_counter: public(uint256)
# array containing the numbers of all active proposals. Important Note: proposal numbers get shuffled in the array as proposals are added or removed after implementation or rejection. they are NOT sorted
proposal_numbers: public(DynArray[uint256, MAX_NUM_PROPOSALS])
# proposal numbers approved and ready for implementation
finalized_proposal_numbers:  public(DynArray[uint256, MAX_NUM_PROPOSALS])
proposals: HashMap[uint256, Proposal] # proposal_number => Proposal struct

# implementation frequency
last_implementation_block: public(uint256)
last_rewards_implementation_block: public(uint256)
end_reward_block: public(uint256)

# how a user voted
user_vote: HashMap[address, HashMap[uint256, UserVote]] # user => proposal_number => UserVote
# how much a user staked
user_locked: HashMap[address, HashMap[address, UserLocked]] # user => desk|self => UserLocked

# how much was staked for a desk
desk_locked: HashMap[address, uint256]
desk_exists: HashMap[address, bool]
desks: DynArray[address, MAX_NUM_DESKS]

# XCRAY issuance
xcray_block_rate: uint256

@external
def __init__(
    _c_token: address,
    _c_control: address,
    _c_treasury: address,
    _xcray_block_rate: uint256
):
    """
    @dev The arguments are chain specific. 
    @param _c_token The address of the XCRAY token contract
    @param _c_control The address of the Crayon Control contract for the chain
    @param _c_treasury The address of the Crayon Treasury smart contract holding protocol-owned liquidity
    @param _xcray_block_rate The number of new XCRAY minted per block
    """

    # yes_vote, redundant. only here because some conversions depend on this being true
    assert MAX_NUM_DESKS <= max_value(int128)
    # make sure token contract address was set
    assert _c_token != empty(address)
    assert CrayonControl(_c_control).is_c_control()

    self.token_contract = ERC20(_c_token)
    self.control_contract = CrayonControl(_c_control)
    self.treasury_contract = CrayonTreasury(_c_treasury)
    self.xcray_block_rate = _xcray_block_rate

    self.end_reward_block = block.number + 6300000 # TODO here OK or make constant?

@external
def new_desk_proposal(
    _proposal_type: ProposalType,
    _desk: address,
    _xc_amount: uint256,
    _param1: uint256,
    _param2: uint256 = 0
):
    """
    @notice Main entry point for proposals aimed at desk settings
    @param _proposal_type The type of proposal. Must be one that is desk related
    @param _desk The address of the desk this proposal is aimed at
    @param _xc_amount The amount of XCRAY the proposer is locking
    @param _param1 New value. Interpretation depends on _proposal_type. 
    @param _param2 Some desk settings require two values to be specified. The second goes here
    """

    assert self._is_for_desk(_proposal_type)

    if _proposal_type != ProposalType.DeskRegistration:
        # if not registering a new desk make sure desk already registered
        assert self.control_contract.is_registered_desk(_desk)

    # special treatment for borrowing fee proposal
    if _proposal_type == ProposalType.BorrowingFee:
        # param1 is new borrowing fee; param2 is the horizon to which it will apply
        assert _param2 != 0

        # assert that horizon exists at desk
        desk: CrayonDesk = CrayonDesk(_desk)
        num_horizons: int128 = desk.num_horizons()
        h: uint256 = 0
        f: uint256 = 0
        found: bool = False
        for i in range(MAX_HORIZONS):
            h, f = desk.get_horizon_and_fee(i)
            if h == _param2:
                found = True
                break
                
            if i + 1 == MAX_HORIZONS:
                break
            
        assert found

    self._new_proposal(True, _proposal_type, _desk, _xc_amount, _param1, _param2)

@external
def new_transfer_proposal(
    _receiver: address,
    _xc_amount: uint256,
    _param1: uint256,
    _param2: uint256
):
    """
    @notice Entry point for proposals to transfer funds out of Crayon Treasury
    @param _receiver The address to transfer to if proposal succeeds. Can be smart contract
    @param _xc_amount The amount of XCRAY the proposer is locking
    @param _param1 The index of the token being transferred as stored in self.treasury_contract
    @param _param2 The amount of the token to transfer
    """

    _proposal_type: ProposalType = ProposalType.Transfer

    self._new_proposal(False, _proposal_type, _receiver, _xc_amount, _param1, _param2)

@external
def new_treasury_token_proposal(
    _proposal_type: ProposalType,
    _xc_amount: uint256,
    _param1: uint256
):
    """
    @notice Add or remove token to list of acceptable tokens in Crayon Treasury
    @param _proposal_type The type of the proposal ProposalType.AddTreasuryToken or ProposalType.RemoveTreasuryToken
    @param _xc_amount The amount of XCRAY the proposer is locking
    @param _param1 The address as uint of the token being added or the index in self.treasury_contract of the token being removed
    """

    assert _proposal_type == ProposalType.AddTreasuryToken or _proposal_type == ProposalType.RemoveTreasuryToken

    # test that param1 is a proper address. this will revert if param1 is not convertible to a uint160
    token_adr: address = convert(_param1, address)
    assert token_adr.is_contract

    self._new_proposal(False, _proposal_type, empty(address), _xc_amount, _param1)

@external
def new_admin_proposal(
    _proposal_type: ProposalType,
    _xc_amount: uint256,
    _param1: uint256
):
    """
    @notice New proposal to change admin for Control or Crayon Treasury
    @param _proposal_type The proposal type  ProposalType.ControlAdmin or ProposalType.TreasuryAdmin
    @param _xc_amount The amount of XCRAY the proposer is locking
    @param _param1 The address of the new admin
    """

    assert _proposal_type == ProposalType.ControlAdmin or _proposal_type == ProposalType.TreasuryAdmin

    # test that param1 is a proper address. this will revert if param1 is not convertible to a uint160
    admin_adr: address = convert(_param1, address)
    assert admin_adr.is_contract

    self._new_proposal(False, _proposal_type, empty(address), _xc_amount, _param1)

@external
def new_xcray_block_rate_proposal(
    _xc_amount: uint256,
    _param1: uint256
):
    """
    @notice Set a new amount of XCRAY to mint every block to distribute as reward
    @param _xc_amount The amount of XCRAY the proposer is locking
    @param _param1 The new amount
    """

    assert _param1 <= 1 # TODO force the xcray reward per block not to exceed 1 XCRAY????

    self._new_proposal(False, ProposalType.XcrayBlockRate, empty(address), _xc_amount, _param1)

@internal
def _new_proposal(
    _is_for_desk: bool,
    _proposal_type: ProposalType,
    _target: address,
    _xc_amount: uint256,
    _param1: uint256,
    _param2: uint256 = 0
):
    """
    @dev Entry point for all new proposals affecting desks registered with self.control_contract. For _proposal_type=ProposalType.DeskRegistration the new desk does not need to be already deployed. _xc_amount can be 0 if user has already locked funds
    @param _is_for_desk Is the proposal desk specific? this controls where the proposer's XCRAY is locked
    @param _proposal_type One of the members of ProposalType
    @param _target Interpretation depends on proposal type
    @param _xc_amount The amount of XCRAY tokens that the proposer (==msg.sender) is locking
    @param _param1 New value. Interpretation depends on _proposal_type. 
    @param _param2 Some settings require two values to be specified. The second goes here
    """

    block_number: uint256 = block.number
    proposer: address = msg.sender

    # _lock_xctoken should at least increment the lockup period regardless of whether the user passed addtional tokens to lock
    lock_target: address = _target if _is_for_desk else self
    self._lock_xctoken(proposer, lock_target, _xc_amount, block_number + LOCKUP_PERIOD)
    xctoken_locked: uint256 = self.user_locked[proposer][lock_target].xctoken_locked
    assert xctoken_locked >= MIN_LOCKABLE
    
    counter: uint256 = self.proposal_counter
    counter += 1

    new_proposal: Proposal = Proposal({is_active: True, is_approved: False, proposal_number: counter, proposal_type: _proposal_type, target: _target, proposer: proposer, to_block: block_number + VOTING_PERIOD, param1: _param1, param2: _param2, num_voters: 1, yes_vote: xctoken_locked, no_vote: 0})

    # register user vote
    self.user_vote[proposer][counter] = UserVote({has_voted: True, in_favor: True})

    # update proposals state
    self.proposal_counter = counter
    self.proposals[counter] = new_proposal
    self.proposal_numbers.append(counter)

    log CrayonProposal(counter, _proposal_type, _target, _param1, _param2)

@external
def stake_for_rewards(
    _desk: address,
    _xc_amount: uint256,
    _period: uint256 = LOCKUP_PERIOD
):
    """
    @notice Stake XCRAY for _desk to participate in setting reward token distribution to _desk. Amount locked also counts toward vote on any proposal concerning _desk
    @param _desk The address of the desk
    @param _xc_amount The amount of XCRAY being staked
    @param _period The number of additional blocks XCRAY is being staked for. Can be any value as long as XCRAY is locked for at least LOCKUP_PERIOD from now
    """

    assert self.control_contract.is_registered_desk(_desk) 
    user_locked: UserLocked = self.user_locked[msg.sender][_desk]
    to_new_block: uint256 = user_locked.to_block + _period
    # so _period can be 0 as long as XCRAY is locked for at least LOCKUP_PERIOD
    assert to_new_block >= block.number + LOCKUP_PERIOD

    self._lock_xctoken(msg.sender, _desk, _xc_amount, to_new_block)

@external
def vote_proposal(
    _proposal_number: uint256,
    _in_favor: bool,
    _xc_amount: uint256
):
    """
    @dev Vote on a proposal. Vote is attributed to msg.sender
    @param _proposal_number The unique proposal number that was assigned when the new proposal was created
    @param _in_favor True means voting for the proposal; False against
    @param _xc_amount The amount of XCRAY token msg.sender is locking for the vote
    """

    proposal: Proposal = self.proposals[_proposal_number]
    assert proposal.is_active

    # lock user tokens and register vote
    user: address = msg.sender
    assert not self.user_vote[user][_proposal_number].has_voted

    lock_target: address = proposal.target if self._is_for_desk(proposal.proposal_type) else self
    self._lock_xctoken(user, lock_target, _xc_amount, block.number + LOCKUP_PERIOD)
    user_locked: uint256 = self.user_locked[user][lock_target].xctoken_locked

    assert user_locked >= MIN_LOCKABLE

    self.user_vote[user][_proposal_number] = UserVote({has_voted: True, in_favor: _in_favor})

    # update vote count for proposal
    if _in_favor:
        proposal.yes_vote += user_locked
    else:
        proposal.no_vote += user_locked

    proposal.num_voters += 1
    self.proposals[_proposal_number] = proposal

@external
def change_vote(
    _proposal_number: uint256,
    _in_favor: bool,
    _xc_amount: uint256
):
    """
    @dev Call this when msg.sender has already voted but decides to change either the vote from yes to no or yes to no; or keep the vote but change the amount of tokens locked
    @param _proposal_number The unique proposal number that was assigned when the new proposal was created
    @param _in_favor The new vote in favor or against the proposal
    @param _xc_amount The amount of tokens (possibly 0) that the user is locking in addition to the tokens locked when the user first voted
    """

    user: address = msg.sender
    user_vote: UserVote = self.user_vote[user][_proposal_number]
    assert user_vote.has_voted

    proposal: Proposal = self.proposals[_proposal_number]
    lock_target: address = proposal.target if self._is_for_desk(proposal.proposal_type) else self

    # if _xc_amount == 0 we don't extend the lockup period since user has already voted on this proposal
    user_first_locked: uint256 = self.user_locked[user][lock_target].xctoken_locked
    if _xc_amount != 0:
        self._lock_xctoken(user, lock_target, _xc_amount, block.number + LOCKUP_PERIOD)
         
    if _in_favor == user_vote.in_favor:
        if _in_favor:
            self.proposals[_proposal_number].yes_vote += _xc_amount
        else:
            self.proposals[_proposal_number].no_vote += _xc_amount
    else:
        if _in_favor:
            self.proposals[_proposal_number].no_vote -= user_first_locked
            self.proposals[_proposal_number].yes_vote += user_first_locked + _xc_amount
        else:
            self.proposals[_proposal_number].yes_vote -= user_first_locked
            self.proposals[_proposal_number].no_vote += user_first_locked + _xc_amount

    self.user_vote[user][_proposal_number].in_favor = _in_favor

@external
@view
def get_user_vote(
    _proposal_number: uint256,
    _user: address
) -> (bool, bool, uint256):
    """
    @dev How did _user vote for proposal
    @param _proposal_number The proposal number
    @param _user The user whose vote is being queried
    @return Returns a triplet: (whether user has voted on this proposal, in favor or not, the amount of XCRAY the user locked)
    """

    user_vote: UserVote = self.user_vote[_user][_proposal_number]
    proposal: Proposal = self.proposals[_proposal_number]
    lock_target: address = proposal.target if self._is_for_desk(proposal.proposal_type) else self

    return (user_vote.has_voted, user_vote.in_favor, self.user_locked[_user][lock_target].xctoken_locked)

@external
@view
def get_proposal_vote(
    _proposal_number: uint256
) -> (uint256, uint256, uint256):
    """
    @dev Get the current count of votes for a proposal
    @param _proposal_number The proposal number
    @return Returns a triplet: (number of users who voted, total XCRAY locked by users who voted for, total XCRAY locked by users who voted against)
    """

    proposal: Proposal = self.proposals[_proposal_number]

    return (proposal.num_voters, proposal.yes_vote, proposal.no_vote)

@internal
@nonreentrant('lock')
def _lock_xctoken(
    _user: address,
    _lock_target: address,
    _xc_amount: uint256,
    _to_block: uint256
):
    """
    @dev Auxiliary function that manages XCRAY token locking
    @param _user The user who is locking XCRAY tokens
    @param _lock_target The address of a desk or self for proposals not concerned with specific desks
    @param _xc_amount The amount of XCRAY tokens to lock. This amount gets added to what's already locked by _user
    @param _to_block The block number until which the XCRAY tokens will be locked. In case, _user is adding to amount already locked _to_block replaces the previous block number
    """

    # we allow _xc_amount == 0. that's the case when the user has already locked tokens for a previous proposal and is proposing/voting again
    if _xc_amount != 0: 
        assert self.token_contract.transferFrom(_user, self, _xc_amount)

    num_locked: uint256 = self.user_locked[_user][_lock_target].xctoken_locked + _xc_amount
    self.user_locked[_user][_lock_target] = UserLocked({xctoken_locked: num_locked, to_block: _to_block})

    # update desk-locked XCRAY
    if _lock_target != self:
        self.desk_locked[_lock_target] += _xc_amount
        if not self.desk_exists[_lock_target]:
            self.desks.append(_lock_target)
            self.desk_exists[_lock_target] = True
    

@external
@view
def get_proposal(
    _proposal_number: uint256
) -> (bool, Bytes[MAX_PROPOSAL_LENGTH]):
    """
    @dev Get proposal details
    @param _proposal_number The proposal number
    @return Returns (is_active, encoded version of the proposal)
    """

    if self.proposals[_proposal_number].is_active:
        return (True, _abi_encode(self.proposals[_proposal_number]))
    else:
        return (False, _abi_encode(empty(Proposal)))

@external
@view
def get_proposal_numbers() -> DynArray[uint256, MAX_NUM_PROPOSALS]:
    """
    @dev Return the numbers of active proposals
    @return Returns an array of all active proposal numbers
    """

    return self.proposal_numbers

@external
@nonreentrant('lock')
def retrieve_xctoken(
    _xc_amount:uint256,
    _desk: address = empty(address)
):
    """
    @dev Get msg.sender's locked tokens back. Reverts if called before block.number until which tokens were locked
    @param _xc_amount The amount of tokens user wants to retrieve. If equal or exceeds locked tokens, all tokens locked by msg.sender are transferred
    """

    user: address = msg.sender
    target: address = _desk if _desk != empty(address) else self
    user_locked: UserLocked = self.user_locked[user][target]
    assert user_locked.to_block >= block.number

    amount: uint256 = _xc_amount
    if amount > user_locked.xctoken_locked:
        amount = user_locked.xctoken_locked

    self.user_locked[user][target].xctoken_locked -= amount
    assert self.token_contract.transfer(user, amount)

@internal
def _add_to_finalized(
    _proposal_number: uint256
) -> bool:
    """
    @dev Add proposal to list of finalized, i.e., ready-for-implemenation proposals, after checking for, and possibly replacing, conflicting proposals
    @param _proposal_number The unique proposal number
    @return Returns True if _proposal_number was added to the list of finalized proposals, False otherwise
    """

    numbers_finalized: DynArray[uint256, MAX_NUM_PROPOSALS] = self.finalized_proposal_numbers
    new_proposal: Proposal = self.proposals[_proposal_number]
    ret: bool = False
    is_found: bool = False
    number_of_finalized: int128 = convert(len(numbers_finalized), int128)
    for i in range(MAX_NUM_PROPOSALS):
        if i >= number_of_finalized:
            break

        proposal: Proposal =  self.proposals[numbers_finalized[i]]
        if new_proposal.proposal_type != proposal.proposal_type or new_proposal.target != proposal.target:
            # no conflict to reconcile
            continue

        # found conflicting proposal
        is_found = True

        # we have a conflict: compare the respective XCRAY participation and, if the same, compare yes votes
        if new_proposal.yes_vote + new_proposal.no_vote > proposal.yes_vote + proposal.no_vote or (new_proposal.yes_vote + new_proposal.no_vote == proposal.yes_vote + proposal.no_vote and new_proposal.yes_vote > proposal.yes_vote):
            # replace conflicting proposal with latest
            self.finalized_proposal_numbers[i] = _proposal_number
            log ProposalConflict(proposal.proposal_number, _proposal_number)
            ret = True
        else:
            # reject latest proposal
            log ProposalConflict(_proposal_number, proposal.proposal_number)
            ret = False

        # there can't be more than one finalized proposal for a given type and target. so break now we've found one
        break

    if not is_found:
        # we're here if no conflict was found
        self.finalized_proposal_numbers.append(_proposal_number)
        ret = True
        
    return ret
        
        
@external
def finalize_proposal(
    _proposal_number: uint256
):
    """
    @dev If voting period ended and vote meets conditions, the proposal is marked approved. Reverts if voting period hasn't ended or proposal is no longer active
    @param _proposal_number The proposal number
    """
    
    proposal: Proposal = self.proposals[_proposal_number]
    assert block.number >= proposal.to_block and proposal.is_active
    
    is_added: bool = False
    # check fraction of yes votes meets constraints
    if proposal.yes_vote > proposal.no_vote and proposal.yes_vote * MIN_FRACTION_DENOMINATOR >= MIN_FRACTION_NUMERATOR * self.token_contract.totalSupply():
        self.proposals[_proposal_number].is_approved = True
        is_added = self._add_to_finalized(_proposal_number)

    if is_added:
        log ProposalApproved(_proposal_number, proposal.num_voters, proposal.yes_vote, proposal.no_vote)
    else:
        log ProposalRejected(_proposal_number, proposal.num_voters, proposal.yes_vote, proposal.no_vote)

    # deactivate to prevent further voting
    self._deactivate_proposal(_proposal_number)

@internal
def _implement_proposal(
    _proposal: Proposal
):
    """
    @dev Implement approved proposal or schedule it for implementation. Calls the appropriate method on self.control_contract
    @param _proposal The proposal to schedule for impleentation
    """

    if _proposal.proposal_type == ProposalType.BorrowingFee:
        self.control_contract.schedule_new_fee(_proposal.param2, _proposal.param1, _proposal.target)
    elif _proposal.proposal_type == ProposalType.FlashloanFee:
        self.control_contract.schedule_new_flashloan_fee(_proposal.param1, _proposal.target)
    elif _proposal.proposal_type == ProposalType.LiquidationBonus:
        self.control_contract.schedule_new_liquidation_bonus(_proposal.param1, _proposal.target)
    elif _proposal.proposal_type == ProposalType.DeskRegistration:
        self.control_contract.register_desk(_proposal.target, _proposal.param1, _proposal.param2)
    elif _proposal.proposal_type == ProposalType.DeskUnregistration:
        self.control_contract.unregister_desk(_proposal.target)
    elif _proposal.proposal_type == ProposalType.ControlAdmin:
        # we need an address. we expect param1 to be uint160
        self.control_contract.set_admin(convert(_proposal.param1, address))
    elif _proposal.proposal_type == ProposalType.TreasuryAdmin:
        # same comment
        self.treasury_contract.set_admin(convert(_proposal.param1, address))
    elif _proposal.proposal_type == ProposalType.AddTreasuryToken:
        # when adding token we pass the address of the token. again param1 should be uint160
        self.treasury_contract.add_token(convert(_proposal.param1, address))
    elif _proposal.proposal_type == ProposalType.RemoveTreasuryToken:
        # when removing token, we pass the index of that token in the Treasury contract
        self.treasury_contract.remove_token(_proposal.param1)
    elif _proposal.proposal_type == ProposalType.Transfer:
        # param1 is the index in the treasury contract of the token we're transferring and param2 is the amount we're transferring
        self.treasury_contract.transfer(_proposal.param1, _proposal.param2, _proposal.target)

    log ProposalImplemented(_proposal.proposal_number)

@external
def implement_proposals():
    """
    @dev Loop through finalized, i.e., approved and inactive, proposals and implement them 
    """

    # Implementation only allowed after certain interval since last one
    assert block.number >= self.last_implementation_block + IMPLEMENTATION_INTERVAL

    for p in self.finalized_proposal_numbers:
        proposal: Proposal = self.proposals[p]
        self._implement_proposal(proposal)
        
    # reset finalized proposals list
    self.finalized_proposal_numbers = empty(DynArray[uint256, MAX_NUM_PROPOSALS])
    self.last_implementation_block = block.number

@external
def implement_new_reward_rates():
    """
    @dev Update XCRAY reward token rates distributed to desks based on relative amounts staked for each desk
    """

    # Implementation only allowed after certain interval since last one
    assert block.number >= self.last_rewards_implementation_block + IMPLEMENTATION_INTERVAL

    total_staked: uint256 = 0
    for desk in self.desks:
        total_staked += self.desk_locked[desk]

    # calculate new reward amounts per desk
    reward_rates: DynArray[uint256, MAX_NUM_DESKS] = empty(DynArray[uint256, MAX_NUM_DESKS])
    if block.number < self.end_reward_block:
        for desk in self.desks:
            # split evenly between lenders and borrowers
            reward_rate: uint256 = self.desk_locked[desk] * self.xcray_block_rate / (total_staked * 2)
            reward_rates.append(reward_rate)
    else:
        # TODO reward program has ended
        for desk in self.desks:
            reward_rate: uint256 = 0
            reward_rates.append(reward_rate)

    self.control_contract.set_desk_rates(self.desks, reward_rates, reward_rates)

    self.last_rewards_implementation_block = block.number

@external
def commit_proposal(
    _proposal_number: uint256
):
    """
    @dev For proposals whose type requires initial scheduling for implementation and that were scheduled on Crayon Control, commit them here
    @param _proposal_number The proposal number
    """

    # these calls will revert in CrayonControl if the changes had not been scheduled properly and/or are not active. no further checks needed here
    proposal: Proposal = self.proposals[_proposal_number]
    if proposal.proposal_type == ProposalType.BorrowingFee:
        self.control_contract.commit_new_fee(proposal.target, proposal.param2)
    elif proposal.proposal_type == ProposalType.FlashloanFee:
        self.control_contract.commit_new_flashloan_fee(proposal.target)
    elif proposal.proposal_type == ProposalType.LiquidationBonus:
        self.control_contract.commit_new_liquidation_bonus(proposal.target)

@internal
def _deactivate_proposal(
    _proposal_number: uint256
):
    """
    @dev Mark proposal as not active and remove it from list of active proposals to prevent further voting
    @param _proposal_number The unique proposal number
    """

    self.proposals[_proposal_number].is_active = False

    # remove _proposal_number from the list of active proposal numbers
    proposal_numbers: DynArray[uint256, MAX_NUM_PROPOSALS] = self.proposal_numbers
    for i in range(MAX_NUM_PROPOSALS):
        if proposal_numbers[i] == _proposal_number:
            proposal_numbers[i] = proposal_numbers[len(proposal_numbers) - 1]
            proposal_numbers.pop()
    self.proposal_numbers = proposal_numbers

@view
@internal
def _is_for_desk(
    _proposal_type: ProposalType
) -> bool:
    """
    @dev Proposals concerning specific desks are different from the rest in the way the locked tokens are labeled. This might be update
    @param _proposal_type The proposal type we're checking
    """

    return convert(_proposal_type, uint256) <= MAX_DESK_PROPOSAL_ENUM