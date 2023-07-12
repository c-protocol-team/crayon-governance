# @version ^0.3.7
# (c) Crayon Protocol Authors, 2023

"""
@title Crayon Protocol Governor
"""

from vyper.interfaces import ERC20

# TODO put bounds on fees and liquidation bonus to prevent human errors although voting process can be counted on to spot those errors

MAX_NUM_PROPOSALS: constant(int128) = 100
MAX_NUM_DESKS: constant(int128) = 20
MAX_PROPOSAL_LENGTH: constant(int128) = 384
MAX_HORIZONS: constant(int128) = 5
VOTING_PERIOD: constant(uint256) = 40320
LOCKUP_PERIOD: constant(uint256) = 2 * VOTING_PERIOD
MIN_LOCKABLE: constant(uint256) = 100 * 10 ** 27
MIN_FRACTION_NUMERATOR: constant(uint256) = 20
MIN_FRACTION_DENOMINATOR: constant(uint256) = 100

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

interface CrayonDesk:
    def num_horizons() -> int128: view
    def get_horizon_and_fee(_ind: int128) -> (uint256, uint256): view

event NewCrayonProposal:
    proposal_number: indexed(uint256)
    proposal_type: indexed(ProposalType)
    desk: indexed(address)
    param1: uint256
    param2: uint256

event ProposalApproved:
    proposal_number: indexed(uint256)
    proposal_type: indexed(ProposalType)
    desk: indexed(address)
    param1: uint256
    param2: uint256
    num_voters: uint256
    yes_vote: uint256
    no_vote: uint256

struct DeskRates:
    borrow_rate: uint256
    deposit_rate: uint256

enum ProposalType:
    BorrowingFee
    FlashloanFee
    LiquidationBonus
    RewardRates
    DeskRegistration
    DeskUnregistration
    ControlAdmin

struct NewProposal:
    is_active: bool
    proposal_number : uint256
    proposal_type: ProposalType
    desk: address
    proposer: address
    to_block: uint256
    param1: uint256
    param2: uint256
    is_approved: bool
    num_voters: uint256
    yes_vote: uint256
    no_vote: uint256

struct UserVote:
    has_voted: bool
    in_favor: bool

struct UserLocked:
    xctoken_locked: uint256
    to_block: uint256

token_contract: public(address)
control_contract: public(address)

# proposals

# an ever-increasing counter for numbering proposals
proposal_counter: public(uint256)
# array containing the numbers of all active proposals. Important Note: proposal numbers get shuffled in the array as proposals are added or removed after implementation or rejection. they are NOT sorted
proposal_numbers: public(DynArray[uint256, MAX_NUM_PROPOSALS])
proposals: HashMap[uint256, NewProposal]

# how a user voted
user_vote: HashMap[address, HashMap[uint256, UserVote]] # user => proposal_number => UserVote
# how much a user staked
user_locked: HashMap[address, UserLocked]

@external
def __init__(
    _token: address,
    _c_control: address
):
    """
    @dev The arguments are chain specific. 
    @param _token The address of the XCRAY token contract
    @param _c_control The address of the Crayon Control contract for the chain 
    """

    # yes_vote, redundant. only here because some conversions depend on this being true
    assert MAX_NUM_DESKS <= max_value(int128)
    # make sure token contract address was set
    assert _token != empty(address)
    assert CrayonControl(_c_control).is_c_control()

    self.token_contract = _token
    self.control_contract = _c_control

@external
def new_proposal(
    _proposal_type: ProposalType,
    _desk: address,
    _xc_amount: uint256,
    _param1: uint256,
    _param2: uint256 = 0
):
    """
    @notice 
    @dev Entry point for all new proposals affecting desks registered with self.control_contract. For _proposal_type=ProposalType.DeskRegistration the new desk does not need to be already deployed. _xc_amount can be 0 if user has already locked funds
    @param _proposal_type One of the members of ProposalType
    @param _desk The address of the desk to which the proposal applies
    @param _xc_amount The amount of XCRAY tokens that the proposer (==msg.sender) is locking
    @param _param1 New value. Interpretation depends on _proposal_type. 
    @param _param2 Some desk settings require two values to be specified. The second goes here
    """

    if _proposal_type != ProposalType.DeskRegistration:
        assert CrayonControl(self.control_contract).is_registered_desk(_desk)

    block_number : uint256 = block.number
    proposer : address = msg.sender

    # _lock_xctoken should at least increment the lockup period regardless of whether the user passed addtional tokens to lock
    self._lock_xctoken(proposer, _xc_amount, block_number + LOCKUP_PERIOD)
    xctoken_locked : uint256 = self.user_locked[proposer].xctoken_locked
    assert xctoken_locked >= MIN_LOCKABLE

    if _proposal_type == ProposalType.BorrowingFee:
        # param1 is new borrowing fee; param2 is the horizon to which it will apply
        assert _param2 != 0

        # assert that horizon exists at desk
        desk : CrayonDesk = CrayonDesk(_desk)
        num_horizons : int128 = desk.num_horizons()
        h : uint256 = 0
        f : uint256 = 0
        found : bool = False
        for i in range(MAX_HORIZONS):
            h, f = desk.get_horizon_and_fee(i)
            if h == _param2:
                found = True
                break
                
            if i + 1 == MAX_HORIZONS:
                break
            
        assert found
    elif _proposal_type == ProposalType.ControlAdmin:
        # test that param1 is a proper address. this will revert if param1 is not convertible to a uint160
        admin_adr : address = convert(_param1, address)
        assert admin_adr.is_contract
    
    counter : uint256 = self.proposal_counter
    counter += 1

    new_proposal : NewProposal = NewProposal({is_active: True, proposal_number: counter, proposal_type: _proposal_type, desk: _desk, proposer: proposer, to_block: block_number + VOTING_PERIOD, param1: _param1, param2: _param2, is_approved: False, num_voters: 1, yes_vote: xctoken_locked, no_vote: 0})

    # register user vote
    self.user_vote[proposer][counter] = UserVote({has_voted: True, in_favor: True})

    # update proposals state
    self.proposal_counter = counter
    self.proposals[counter] = new_proposal
    self.proposal_numbers.append(counter)

    log NewCrayonProposal(counter, _proposal_type, _desk, _param1, _param2)

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

    proposal : NewProposal = self.proposals[_proposal_number]
    assert proposal.is_active

    # lock user tokens and register vote
    user : address = msg.sender
    assert not self.user_vote[user][_proposal_number].has_voted

    self._lock_xctoken(user, _xc_amount, block.number + LOCKUP_PERIOD)
    user_locked : uint256 = self.user_locked[user].xctoken_locked

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
    @param _in_favor The new vote in favor or against the proposal
    @param _xc_amount The amount of tokens (possibly 0) that the user is locking in addition to the tokens locked when the user first voted
    """

    user : address = msg.sender
    user_vote : UserVote = self.user_vote[user][_proposal_number]
    assert user_vote.has_voted

    # if _xc_amount == 0 we don't extend the lockup period since user has already voted on this proposal
    user_first_locked : uint256 = self.user_locked[user].xctoken_locked
    if _xc_amount != 0:
        self._lock_xctoken(user, _xc_amount, block.number + LOCKUP_PERIOD)
        
    
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

    user_vote : UserVote = self.user_vote[_user][_proposal_number]

    return (user_vote.has_voted, user_vote.in_favor, self.user_locked[_user].xctoken_locked)

@external
@view
def get_proposal_vote(
    _proposal_number: uint256
) -> (uint256, uint256, uint256):
    """
    @dev Get the current count of votes for a proposal
    @param _proposal_number The proposal number
    @return Returns a triplet: (number of users who voted for or against proposal, total XCRAY locked by users who voted for, total XCRAY locked by users who voted against)
    """

    proposal : NewProposal = self.proposals[_proposal_number]

    return (proposal.num_voters, proposal.yes_vote, proposal.no_vote)

@internal
def _lock_xctoken(
    _user : address,
    _xc_amount : uint256,
    _to_block: uint256
):
    """
    @dev Auxiliary function that manages XCRAY token locking
    @param _user The user who is locking XCRAY tokens
    @param _xc_amount The amount of XCRAY tokens to lock. This amount gets added to what's already locked by _user
    @param _to_block The block number until which the XCRAY tokens will be locked. In case, _user is adding to amount already locked _to_block replaces the previous block number
    """

    # we allow _xc_amount == 0. that's the case when the user has already locked tokens for a previous proposal and is proposing/voting again
    if _xc_amount != 0: 
        assert ERC20(self.token_contract).transferFrom(_user, self, _xc_amount)

    num_locked : uint256 = self.user_locked[_user].xctoken_locked + _xc_amount
    self.user_locked[_user] = UserLocked({xctoken_locked: num_locked, to_block: _to_block})

@external
@view
def get_proposal(
    _proposal_number: uint256
) -> (bool, Bytes[MAX_PROPOSAL_LENGTH]):
    """
    @dev Get proposal details
    @param _proposal_number The proposal number
    @return Returns an encoded version of the proposal
    """

    if self.proposals[_proposal_number].is_active:
        return (True, _abi_encode(self.proposals[_proposal_number]))
    else:
        return (False, _abi_encode(empty(NewProposal)))

@external
@view
def get_proposal_numbers() -> DynArray[uint256, MAX_NUM_PROPOSALS]:
    """
    @dev Return the numbers of active proposals
    @return Returns an array of all active proposal numbers
    """

    return self.proposal_numbers

@external
def retrieve_xctoken(
    _xc_amount :uint256
):
    """
    @dev Get msg.sender's locked tokens back. Reverts if called before block.number until which tokens were locked
    @param _xc_amount The amount of tokens user wants to retrieve. If equal or exceeds locked tokens, all tokens locked by msg.sender are transferred
    """

    user : address = msg.sender
    user_locked : UserLocked = self.user_locked[user]
    assert user_locked.to_block >= block.number

    amount : uint256 = _xc_amount
    if amount > user_locked.xctoken_locked:
        amount = user_locked.xctoken_locked

    assert ERC20(self.token_contract).transfer(user, amount)

@external
def finalize_proposal(
    _proposal_number: uint256
):
    """
    @dev If voting period ended and vote meets conditions, the proposal is marked approved. Reverts if voting period hasn't ended or proposal is no longer active
    @param _proposal_number The proposal number
    """
    
    proposal : NewProposal = self.proposals[_proposal_number]
    assert block.number >= proposal.to_block and proposal.is_active
    if proposal.yes_vote * MIN_FRACTION_DENOMINATOR >= MIN_FRACTION_NUMERATOR * ERC20(self.token_contract).totalSupply():
        self.proposals[_proposal_number].is_approved = True

        log ProposalApproved(_proposal_number, proposal.proposal_type, proposal.desk, proposal.param1, proposal.param2, proposal.num_voters, proposal.yes_vote, proposal.no_vote)
    else:
        self._deactivate_proposal(_proposal_number)

@external
def implement_proposal(
    _proposal_number: uint256
):
    """
    @dev Implement approved proposal or schedule it for implementation. Calls the appropriate method on self.control_contract
    @param _proposal_number The proposal number
    """

    proposal : NewProposal = self.proposals[_proposal_number]
    assert proposal.is_active and proposal.is_approved

    crayon_control : CrayonControl = CrayonControl(self.control_contract)
    if proposal.proposal_type == ProposalType.BorrowingFee:
        crayon_control.schedule_new_fee(proposal.param2, proposal.param1, proposal.desk)
    elif proposal.proposal_type == ProposalType.FlashloanFee:
        crayon_control.schedule_new_flashloan_fee(proposal.param1, proposal.desk)
    elif proposal.proposal_type == ProposalType.LiquidationBonus:
        crayon_control.schedule_new_liquidation_bonus(proposal.param1, proposal.desk)
    elif proposal.proposal_type == ProposalType.RewardRates:
        crayon_control.set_desk_rates([proposal.desk], [proposal.param1], [proposal.param2])
    elif proposal.proposal_type == ProposalType.DeskRegistration:
        crayon_control.register_desk(proposal.desk, proposal.param1, proposal.param2)
    elif proposal.proposal_type == ProposalType.DeskUnregistration:
        crayon_control.unregister_desk(proposal.desk)
    elif proposal.proposal_type == ProposalType.ControlAdmin:
        crayon_control.set_admin(convert(proposal.param1, address))

    self._deactivate_proposal(_proposal_number)

@external
def commit_proposal(
    _proposal_number: uint256
):
    """
    @dev For proposals that were scheduled for implementation, commit them 
    @param _proposal_number The proposal number
    """

    # these calls will revert in CrayonControl if the changes had not been scheduled properly and/or are not active. no further checks needed here
    proposal : NewProposal = self.proposals[_proposal_number]
    crayon_control : CrayonControl = CrayonControl(self.control_contract)
    if proposal.proposal_type == ProposalType.BorrowingFee:
        crayon_control.commit_new_fee(proposal.desk, proposal.param2)
    elif proposal.proposal_type == ProposalType.FlashloanFee:
        crayon_control.commit_new_flashloan_fee(proposal.desk)
    elif proposal.proposal_type == ProposalType.LiquidationBonus:
        crayon_control.commit_new_liquidation_bonus(proposal.desk)

@internal
def _deactivate_proposal(
    _proposal_number: uint256
):
    """
    @dev Mark proposal as not active and remove it from list of active proposals
    @param _proposal_number The proposal number
    """

    self.proposals[_proposal_number].is_active = False

    # remove _proposal_number from the list of active proposal numbers
    proposal_numbers : DynArray[uint256, MAX_NUM_PROPOSALS] = self.proposal_numbers
    for i in range(MAX_NUM_PROPOSALS):
        if proposal_numbers[i] == _proposal_number:
            proposal_numbers[i] = proposal_numbers[len(proposal_numbers) - 1]
            proposal_numbers.pop()
    self.proposal_numbers = proposal_numbers