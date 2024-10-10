# @version ^0.3.7
# (c) Crayon Protocol Authors, 2023

"""
@title Crayon Protocol Treasury Contract
"""

from vyper.interfaces import ERC20

# minimum number of blocks passed since last transfer
MIN_TRANSFER_INTERVAL: constant(uint256) = 5760
# maximum fraction of treasury balance that can be transferred in one transaction
MAX_TRANSFER_FRACTION_NUM: constant(uint256) = 5
MAX_TRANSFER_FRACTION_DENOM: constant(uint256) = 100

num_tokens: public(uint256)
tokens: public(HashMap[uint256, address])
admin: public(address)
last_transfer_block: public(HashMap[uint256, uint256]) # token_index => last_transfer_block

@external
def __init__(
    _admin: address
):
    # expected to be the governor contract
    self.admin = _admin

@external
def add_token(
    _token: address
):
    """
    @notice Add token to the treasury mix
    @param _token The address of the token being added
    """

    assert msg.sender == self.admin

    self.tokens[self.num_tokens] = _token
    self.num_tokens += 1

@external
def remove_token(
    _ind: uint256
):
    """
    @notice Remove token from the mix of held tokens. Treasury's balance must be 0 to remove the token
    @param _ind The index of the token being removed
    """

    assert msg.sender == self.admin

    token_address: address = self.tokens[_ind]
    # make sure balance is 0
    assert ERC20(token_address).balanceOf(self) == 0
    self.tokens[_ind] = empty(address)

@external
def transfer(
    _ind: uint256,
    _amount: uint256,
    _receiver: address
):
    """
    @notice Transfer some amount of tokens to receiver
    @dev Only one transfer per token in any MIN_TRANSFER_INTERVAL number of blocks and only for amount less than MAX_TRANSFER_FRACTION_NUM / MAX_TRANSFER_FRACTION_DENOM * self_balance
    @param _ind The index of the token to transfer
    @param _amount The amount of tokens to transfer
    @param _receiver The address of the receiver which might be a smart contract
    """

    assert msg.sender == self.admin
    assert block.number >= self.last_transfer_block[_ind] + MIN_TRANSFER_INTERVAL
    
    token: ERC20 = ERC20(self.tokens[_ind])

    bal : uint256 = token.balanceOf(self)
    assert _amount * MAX_TRANSFER_FRACTION_DENOM <= bal * MAX_TRANSFER_FRACTION_NUM

    self.last_transfer_block[_ind] = block.number
    token.transfer(_receiver, _amount)

@external
def set_admin(
    _new_admin: address
):
    """
    @notice Set admin to new address expected to be new Governor contract deployment
    @param _new_admin The address of new admin
    """

    assert msg.sender == self.admin
    assert _new_admin.is_contract

    self.admin = _new_admin