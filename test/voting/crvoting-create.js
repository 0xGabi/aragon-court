const { OUTCOMES } = require('../helpers/crvoting')
const { assertRevert } = require('@aragon/test-helpers/assertThrow')
const { decodeEventsOfType } = require('../helpers/decodeEvent')
const { assertEvent, assertAmountOfEvents } = require('@aragon/test-helpers/assertEvent')(web3)

const CRVoting = artifacts.require('CRVoting')
const CRVotingOwner = artifacts.require('CRVotingOwnerMock')

contract('CRVoting create', ([_, someone]) => {
  let voting, votingOwner

  beforeEach('create base contracts', async () => {
    voting = await CRVoting.new()
    votingOwner = await CRVotingOwner.new(voting.address)
  })

  describe('create', () => {
    context('when the voting is initialized', () => {
      beforeEach('initialize voting', async () => {
        await voting.init(votingOwner.address)
      })

      context('when the sender is the owner', () => {
        const voteId = 1

        context('when the given vote ID was not used before', () => {
          context('when the given possible outcomes is valid', () => {
            const possibleOutcomes = 5

            it('creates the given voting', async () => {
              await votingOwner.create(voteId, possibleOutcomes)

              assert.isTrue(await voting.isValidOutcome(voteId, OUTCOMES.REFUSED), 'refused outcome should be invalid')
              assert.equal((await voting.getMaxAllowedOutcome(voteId)).toString(), possibleOutcomes + OUTCOMES.REFUSED, 'max allowed outcome does not match')
            })

            it('emits an event', async () => {
              const { tx } = await votingOwner.create(voteId, possibleOutcomes)
              const receipt = await web3.eth.getTransactionReceipt(tx)
              const logs = decodeEventsOfType({ receipt }, CRVoting.abi, 'VotingCreated')

              assertAmountOfEvents({ logs }, 'VotingCreated')
              assertEvent({ logs }, 'VotingCreated', { voteId, possibleOutcomes })
            })

            it('considers as valid outcomes any of the possible ones', async () => {
              await votingOwner.create(voteId, possibleOutcomes)

              const masAllowedOutcome = (await voting.getMaxAllowedOutcome(voteId)).toNumber()
              for (let outcome = OUTCOMES.REFUSED + 1; outcome <= masAllowedOutcome; outcome++) {
                assert.isTrue(await voting.isValidOutcome(voteId, outcome), 'outcome should be valid')
              }
            })

            it('considers the missing and leaked outcomes invalid', async () => {
              await votingOwner.create(voteId, possibleOutcomes)

              assert.isFalse(await voting.isValidOutcome(voteId, OUTCOMES.MISSING), 'missing outcome should be invalid')
              assert.isFalse(await voting.isValidOutcome(voteId, OUTCOMES.LEAKED), 'leaked outcome should be invalid')
            })

            it('considers refused as the winning outcome initially', async () => {
              await votingOwner.create(voteId, possibleOutcomes)

              assert.equal((await voting.getWinningOutcome(voteId)).toString(), OUTCOMES.REFUSED, 'winning outcome does not match')
            })
          })

          context('when the possible outcomes below the minimum', () => {
            it('reverts', async () => {
              await assertRevert(votingOwner.create(voteId, 0), 'CRV_INVALID_OUTCOMES_AMOUNT')
              await assertRevert(votingOwner.create(voteId, 1), 'CRV_INVALID_OUTCOMES_AMOUNT')
            })
          })

          context('when the possible outcomes above the maximum', () => {
            it('reverts', async () => {
              await assertRevert(votingOwner.create(voteId, 510), 'CRV_INVALID_OUTCOMES_AMOUNT')
            })
          })
        })

        context('when the given vote ID was already used', () => {
          beforeEach('create voting', async () => {
            await votingOwner.create(voteId, 2)
          })

          it('reverts', async () => {
            await assertRevert(votingOwner.create(voteId, 2), 'CRV_VOTE_ALREADY_EXISTS')
          })
        })
      })

      context('when the sender is not the owner', () => {
        const from = someone

        it('reverts', async () => {
          await assertRevert(voting.create(1, 2, { from }), 'CRV_SENDER_NOT_OWNER')
        })
      })

    })

    context('when the voting is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(voting.create(1, 2, { from: someone }), 'CRV_SENDER_NOT_OWNER')
      })
    })
  })
})
