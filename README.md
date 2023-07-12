# crayon-protocol-governor

Vyper contracts implementing mechanisms to control Crayon Protocol desks.

## Governance

Governance of the Crayon Protocol is concerned with deciding:

* The desks to deploy including their longables (tokens accepted as collateral) and horizons (loan durations).
* Setting and re-setting various fees on those desks.
* Setting and re-setting reward token distributions (``XCRAY`` tokens).

Fees and reward token distributions are managed on an on-going basis.

Approved governance decisions are executed through the ``Control`` smart contract where deployed desks are registered. The ``admin`` address in ``Control`` is the only address empowered to register newly deployed desks and set and reset fees and reward rates.

### Current state

This is a preliminary implementation principally meant to invite community feedback that we'll iterate over for release some time in Summer 2023.

