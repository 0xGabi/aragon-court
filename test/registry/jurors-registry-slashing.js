const { bn, bigExp } = require('../helpers/numbers')(web3)
const { getEventAt } = require('@aragon/test-helpers/events')
const { assertRevert } = require('@aragon/test-helpers/assertThrow')
const { decodeEventsOfType } = require('../helpers/decodeEvent')
const { assertEvent, assertAmountOfEvents } = require('@aragon/test-helpers/assertEvent')(web3)

const MiniMeToken = artifacts.require('MiniMeToken')
const JurorsRegistry = artifacts.require('JurorsRegistryMock')
const JurorsRegistryOwnerMock = artifacts.require('JurorsRegistryOwnerMock')

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

contract('JurorsRegistry slashing', ([_, juror, secondJuror, thirdJuror, anyone]) => {
  let registry, registryOwner, ANJ

  const ACTIVATE_DATA = web3.sha3('activate(uint256)').slice(0, 10)
  const MIN_ACTIVE_AMOUNT = bigExp(100, 18)
  const DRAFT_LOCK_PCT = bn(2000) // 20%
  const DRAFT_LOCK_AMOUNT = MIN_ACTIVE_AMOUNT.mul(DRAFT_LOCK_PCT.div(10000))
  const EMPTY_RANDOMNESS = '0x0000000000000000000000000000000000000000000000000000000000000000'

  beforeEach('create base contracts', async () => {
    registry = await JurorsRegistry.new()
    registryOwner = await JurorsRegistryOwnerMock.new(registry.address)
    ANJ = await MiniMeToken.new(ZERO_ADDRESS, ZERO_ADDRESS, 0, 'n', 18, 'ANJ', true)
  })

  describe('slashOrUnlock', () => {
    context('when the registry is initialized', () => {
      beforeEach('initialize registry', async () => {
        await registry.init(registryOwner.address, ANJ.address, MIN_ACTIVE_AMOUNT)
      })

      context('when the sender is the owner', () => {
        beforeEach('activate jurors', async () => {
          const firstJurorBalance = MIN_ACTIVE_AMOUNT.mul(10)
          await ANJ.generateTokens(juror, firstJurorBalance)
          await ANJ.approveAndCall(registry.address, firstJurorBalance, ACTIVATE_DATA, { from: juror })

          const secondJurorBalance = MIN_ACTIVE_AMOUNT.mul(5)
          await ANJ.generateTokens(secondJuror, secondJurorBalance)
          await ANJ.approveAndCall(registry.address, secondJurorBalance, ACTIVATE_DATA, { from: secondJuror })

          const thirdJurorBalance = MIN_ACTIVE_AMOUNT.mul(20)
          await ANJ.generateTokens(thirdJuror, thirdJurorBalance)
          await ANJ.approveAndCall(registry.address, thirdJurorBalance, ACTIVATE_DATA, { from: thirdJuror })

          await registryOwner.incrementTerm()
        })

        context('when given input length does not match', () => {
          context('when given locked amounts do not match jurors length', () => {
            const jurors = []
            const lockedAmounts = [1]
            const rewardedJurors = []

            it('reverts', async () => {
              await assertRevert(registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors), 'JR_INVALID_LOCKED_AMOUNTS_LEN')
            })
          })

          context('when given rewarded jurors do not match jurors length', () => {
            const jurors = []
            const lockedAmounts = []
            const rewardedJurors = [true]

            it('reverts', async () => {
              await assertRevert(registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors), 'JR_INVALID_REWARDED_JURORS_LEN')
            })
          })
        })

        context('when given input length matches', () => {
          context('when no jurors are given', () => {
            const jurors = []
            const lockedAmounts = []
            const rewardedJurors = []

            it('does not collect tokens', async () => {
              const receipt = await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)
              assertEvent(receipt, 'Slashed', { collected: 0 })
            })

            it('does not affect the balances of the jurors', async () => {
              const previousFirstJurorBalances = await registry.balanceOf(juror)
              const previousSecondJurorBalances = await registry.balanceOf(secondJuror)
              const previousThirdJurorBalances = await registry.balanceOf(thirdJuror)

              await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)

              const currentJurorBalances = await registry.balanceOf(juror)
              const currentSecondJurorBalances = await registry.balanceOf(secondJuror)
              const currentThirdJurorBalances = await registry.balanceOf(thirdJuror)

              for (let i = 0; i < currentJurorBalances.length; i++) {
                assert.equal(previousFirstJurorBalances[i].toString(), currentJurorBalances[i].toString(), `first juror balance #${i} does not match`)
                assert.equal(previousSecondJurorBalances[i].toString(), currentSecondJurorBalances[i].toString(), `second juror balance #${i} does not match`)
                assert.equal(previousThirdJurorBalances[i].toString(), currentThirdJurorBalances[i].toString(), `third juror balance #${i} does not match`)
              }
            })
          })

          context('when some jurors are given', () => {
            const jurors = [juror, secondJuror, thirdJuror]
            const rewardedJurors = [false, true, false]

            beforeEach('draft jurors', async () => {
              // Mock registry draft forcing the following result
              const draftedJurors = [juror, secondJuror, thirdJuror]
              const draftedWeights = [3, 1, 6]
              await registry.mockNextDraft(draftedJurors, draftedWeights)

              // Draft and make sure mock worked as expected
              const receipt = await registryOwner.draft(EMPTY_RANDOMNESS, 1, 0, 10, 10, DRAFT_LOCK_PCT)
              const { addresses, weights } = getEventAt(receipt, 'Drafted').args

              assert.equal(addresses[0], juror, 'first drafted address does not match')
              assert.equal(addresses[1], secondJuror, 'second drafted address does not match')
              assert.equal(addresses[2], thirdJuror, 'third drafted address does not match')
              assert.equal(weights[0].toString(), 3, 'first drafted weight does not match')
              assert.equal(weights[1].toString(), 1, 'second drafted weight does not match')
              assert.equal(weights[2].toString(), 6, 'third drafted weight does not match')
            })

            context('when given lock amounts are valid', () => {
              const lockedAmounts = [DRAFT_LOCK_AMOUNT.mul(3), DRAFT_LOCK_AMOUNT, DRAFT_LOCK_AMOUNT.mul(6)]

              it('collect tokens for all the slashed amounts', async () => {
                const receipt = await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)
                assertEvent(receipt, 'Slashed', { collected: DRAFT_LOCK_AMOUNT.mul(9) })
              })

              it('unlocks balances of the rewarded jurors', async () => {
                const [previousActiveBalance, previousAvailableBalance, previousLockedBalance, previousDeactivationBalance] = await registry.balanceOf(secondJuror)

                await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)

                const [currentActiveBalance, currentAvailableBalance, currentLockedBalance, currentDeactivationBalance] = await registry.balanceOf(secondJuror)
                assert.equal(previousLockedBalance.minus(DRAFT_LOCK_AMOUNT).toString(), currentLockedBalance.toString(), 'rewarded juror locked balance does not match')
                assert.equal(previousActiveBalance.toString(), currentActiveBalance.toString(), 'rewarded juror active balance does not match')
                assert.equal(previousAvailableBalance.toString(), currentAvailableBalance.toString(), 'rewarded juror available balance does not match')
                assert.equal(previousDeactivationBalance.toString(), currentDeactivationBalance.toString(), 'rewarded juror deactivation balance does not match')
              })

              it('slashes the active balances of the not rewarded jurors', async () => {
                const [firstJurorPreviousActiveBalance, firstJurorPreviousAvailableBalance, firstJurorPreviousLockedBalance, firstJurorPreviousDeactivationBalance] = await registry.balanceOf(juror)
                const [thirdJurorPreviousActiveBalance, thirdJurorPreviousAvailableBalance, thirdJurorPreviousLockedBalance, thirdJurorPreviousDeactivationBalance] = await registry.balanceOf(thirdJuror)

                await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)

                const [firstJurorCurrentActiveBalance, firstJurorCurrentAvailableBalance, firstJurorCurrentLockedBalance, firstJurorCurrentDeactivationBalance] = await registry.balanceOf(juror)
                assert.equal(firstJurorPreviousLockedBalance.minus(DRAFT_LOCK_AMOUNT.mul(3)).toString(), firstJurorCurrentLockedBalance.toString(), 'first slashed juror locked balance does not match')
                assert.equal(firstJurorPreviousActiveBalance.minus(DRAFT_LOCK_AMOUNT.mul(3)).toString(), firstJurorCurrentActiveBalance.toString(), 'first slashed juror active balance does not match')
                assert.equal(firstJurorPreviousAvailableBalance.toString(), firstJurorCurrentAvailableBalance.toString(), 'first slashed juror available balance does not match')
                assert.equal(firstJurorPreviousDeactivationBalance.toString(), firstJurorCurrentDeactivationBalance.toString(), 'first slashed juror deactivation balance does not match')

                const [thirdJurorCurrentActiveBalance, thirdJurorCurrentAvailableBalance, thirdJurorCurrentLockedBalance, thirdJurorCurrentDeactivationBalance] = await registry.balanceOf(thirdJuror)
                assert.equal(thirdJurorPreviousLockedBalance.minus(DRAFT_LOCK_AMOUNT.mul(6)).toString(), thirdJurorCurrentLockedBalance.toString(), 'second slashed juror locked balance does not match')
                assert.equal(thirdJurorPreviousActiveBalance.minus(DRAFT_LOCK_AMOUNT.mul(6)).toString(), thirdJurorCurrentActiveBalance.toString(), 'second slashed juror active balance does not match')
                assert.equal(thirdJurorPreviousAvailableBalance.toString(), thirdJurorCurrentAvailableBalance.toString(), 'second slashed juror available balance does not match')
                assert.equal(thirdJurorPreviousDeactivationBalance.toString(), thirdJurorCurrentDeactivationBalance.toString(), 'second slashed juror deactivation balance does not match')
              })

              it('does not affect the active balances of the current term', async () => {
                let termId = await registryOwner.getLastEnsuredTermId()
                const firstJurorPreviousActiveBalance = await registry.activeBalanceOfAt(juror, termId)
                const secondJurorPreviousActiveBalance = await registry.activeBalanceOfAt(secondJuror, termId)
                const thirdJurorPreviousActiveBalance = await registry.activeBalanceOfAt(thirdJuror, termId)

                await registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors)

                const firstJurorCurrentActiveBalance = await registry.activeBalanceOfAt(juror, termId)
                assert.equal(firstJurorPreviousActiveBalance.toString(), firstJurorCurrentActiveBalance.toString(), 'first juror active balance does not match')

                const secondJurorCurrentActiveBalance = await registry.activeBalanceOfAt(secondJuror, termId)
                assert.equal(secondJurorPreviousActiveBalance.toString(), secondJurorCurrentActiveBalance.toString(), 'second juror active balance does not match')

                const thirdJurorCurrentActiveBalance = await registry.activeBalanceOfAt(thirdJuror, termId)
                assert.equal(thirdJurorPreviousActiveBalance.toString(), thirdJurorCurrentActiveBalance.toString(), 'third juror active balance does not match')
              })
            })

            context('when given lock amounts are not valid', () => {
              const lockedAmounts = [DRAFT_LOCK_AMOUNT.mul(10), 0, 0]

              it('reverts', async () => {
                await assertRevert(registryOwner.slashOrUnlock(jurors, lockedAmounts, rewardedJurors), 'MATH_SUB_UNDERFLOW')
              })
            })
          })
        })
      })

      context('when the sender is not the owner', () => {
        it('reverts', async () => {
          await assertRevert(registry.slashOrUnlock(0, [], [], []), 'JR_SENDER_NOT_OWNER')
        })
      })
    })

    context('when the registry is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(registryOwner.slashOrUnlock([], [], []), 'JR_SENDER_NOT_OWNER')
      })
    })
  })

  describe('collectTokens', () => {
    context('when the registry is initialized', () => {
      beforeEach('initialize registry', async () => {
        await registry.init(registryOwner.address, ANJ.address, MIN_ACTIVE_AMOUNT)
      })

      context('when the sender is the owner', () => {
        const itReturnsFalse = amount => {
          it('returns false', async () => {
            const receipt = await registryOwner.collect(juror, amount)
            assertEvent(receipt, 'Collected', { collected: false })
          })
        }

        const itHandlesTokensCollectionFor = (amount, deactivationReduced = 0) => {
          it('returns true', async () => {
            const receipt = await registryOwner.collect(juror, amount)
            assertEvent(receipt, 'Collected', { collected: true })
          })

          it('decreases the active balance of the juror', async () => {
            const [previousActiveBalance, previousAvailableBalance, previousLockedBalance, previousDeactivationBalance] = await registry.balanceOf(juror)

            await registryOwner.collect(juror, amount)

            const [currentActiveBalance, currentAvailableBalance, currentLockedBalance, currentDeactivationBalance] = await registry.balanceOf(juror)
            assert.equal(previousDeactivationBalance.minus(deactivationReduced).toString(), currentDeactivationBalance.toString(), 'deactivation balances do not match')
            assert.equal(previousActiveBalance.minus(amount).plus(deactivationReduced).toString(), currentActiveBalance.toString(), 'active balances do not match')

            assert.equal(previousLockedBalance.toString(), currentLockedBalance.toString(), 'locked balances do not match')
            assert.equal(previousAvailableBalance.toString(), currentAvailableBalance.toString(), 'available balances do not match')
          })

          it('does not affect the active balance of the current term', async () => {
            const termId = await registryOwner.getLastEnsuredTermId()
            const currentTermPreviousBalance = await registry.activeBalanceOfAt(juror, termId)

            await registryOwner.collect(juror, amount)

            const currentTermCurrentBalance = await registry.activeBalanceOfAt(juror, termId)
            assert.equal(currentTermPreviousBalance.toString(), currentTermCurrentBalance.toString(), 'current term active balances do not match')
          })

          it('decreases the unlocked balance of the juror', async () => {
            const previousUnlockedActiveBalance = await registry.unlockedActiveBalanceOf(juror)

            await registryOwner.collect(juror, amount)

            const currentUnlockedActiveBalance = await registry.unlockedActiveBalanceOf(juror)
            assert.equal(previousUnlockedActiveBalance.minus(amount).plus(deactivationReduced).toString(), currentUnlockedActiveBalance.toString(), 'unlocked balances do not match')
          })

          it('decreases the staked balance of the juror', async () => {
            const previousTotalStake = await registry.totalStaked()
            const previousJurorStake = await registry.totalStakedFor(juror)

            await registryOwner.collect(juror, amount)

            const currentTotalStake = await registry.totalStaked()
            assert.equal(previousTotalStake.toString(), currentTotalStake.toString(), 'total stake amounts do not match')

            const currentJurorStake = await registry.totalStakedFor(juror)
            assert.equal(previousJurorStake.minus(amount).toString(), currentJurorStake.toString(), 'juror stake amounts do not match')
          })

          it('does not affect the token balances', async () => {
            const previousJurorBalance = await ANJ.balanceOf(juror)
            const previousRegistryBalance = await ANJ.balanceOf(registry.address)

            await registryOwner.collect(juror, amount)

            const currentSenderBalance = await ANJ.balanceOf(juror)
            assert.equal(previousJurorBalance.toString(), currentSenderBalance.toString(), 'juror balances do not match')

            const currentRegistryBalance = await ANJ.balanceOf(registry.address)
            assert.equal(previousRegistryBalance.toString(), currentRegistryBalance.toString(), 'registry balances do not match')
          })

          if (amount === 0) {
            it('does not emit a juror tokens collected event', async () => {
              const { tx } = await registryOwner.collect(juror, amount)
              const receipt = await web3.eth.getTransactionReceipt(tx)
              const logs = decodeEventsOfType({ receipt }, JurorsRegistry.abi, 'JurorTokensCollected')

              assertAmountOfEvents({ logs }, 'JurorTokensCollected', 0)
            })
          } else {
            it('emits a juror tokens collected event', async () => {
              const termId = await registryOwner.getLastEnsuredTermId()

              const { tx } = await registryOwner.collect(juror, amount)
              const receipt = await web3.eth.getTransactionReceipt(tx)
              const logs = decodeEventsOfType({ receipt }, JurorsRegistry.abi, 'JurorTokensCollected')

              assertAmountOfEvents({ logs }, 'JurorTokensCollected')
              assertEvent({ logs }, 'JurorTokensCollected', { juror: web3.toChecksumAddress(juror), termId: termId.plus(1), amount })
            })
          }

          it('does not process deactivation requests', async () => {
            const receipt = await registryOwner.collect(juror, amount)

            assertAmountOfEvents(receipt, 'JurorDeactivationProcessed', 0)
          })

          if (deactivationReduced !== 0) {
            it('emits a deactivation request updated event', async () => {
              const termId = await registryOwner.getLastEnsuredTermId()
              const [, , , previousDeactivationBalance] = await registry.balanceOf(juror)

              const { tx } = await registryOwner.collect(juror, amount)
              const receipt = await web3.eth.getTransactionReceipt(tx)
              const logs = decodeEventsOfType({ receipt }, JurorsRegistry.abi, 'JurorDeactivationUpdated')

              assertAmountOfEvents({ logs }, 'JurorDeactivationUpdated')
              assertEvent({ logs }, 'JurorDeactivationUpdated', {
                juror: web3.toChecksumAddress(juror),
                amount: previousDeactivationBalance.minus(deactivationReduced),
                availableTermId: 1,
                updateTermId: termId
              })
            })
          }
        }

        context('when the juror has not staked some tokens yet', () => {
          context('when the given amount is zero', () => {
            const amount = 0

            itHandlesTokensCollectionFor(amount)
          })

          context('when the given amount is greater than zero', () => {
            const amount = bigExp(50, 18)

            itReturnsFalse(amount)
          })
        })

        context('when the juror has already staked some tokens', () => {
          const stakedBalance = MIN_ACTIVE_AMOUNT.times(5)

          beforeEach('stake some tokens', async () => {
            await ANJ.generateTokens(juror, stakedBalance)
            await ANJ.approveAndCall(registry.address, stakedBalance, '0x', { from: juror })
          })

          context('when the juror did not activate any tokens yet', () => {
            context('when the given amount is zero', () => {
              const amount = 0

              itHandlesTokensCollectionFor(amount)
            })

            context('when the given amount is lower than the available balance of the juror', () => {
              const amount = stakedBalance.minus(1)

              itReturnsFalse(amount)
            })

            context('when the given amount is greater than the available balance of the juror', () => {
              const amount = stakedBalance.plus(1)

              itReturnsFalse(amount)
            })
          })

          context('when the juror has already activated some tokens', () => {
            const activeBalance = MIN_ACTIVE_AMOUNT.times(4)

            beforeEach('activate some tokens', async () => {
              await registry.activate(activeBalance, { from: juror })
            })

            context('when the juror does not have a deactivation request', () => {
              context('when the given amount is zero', () => {
                const amount = 0

                itHandlesTokensCollectionFor(amount)
              })

              context('when the given amount is lower than the active balance of the juror', () => {
                const amount = activeBalance.minus(1)

                itHandlesTokensCollectionFor(amount)
              })

              context('when the given amount is lower than the active balance of the juror', () => {
                const amount = activeBalance.plus(1)

                itReturnsFalse(amount)
              })
            })

            context('when the juror already has a previous deactivation request', () => {
              const deactivationAmount = MIN_ACTIVE_AMOUNT
              const currentActiveBalance = activeBalance.minus(deactivationAmount)

              beforeEach('deactivate tokens', async () => {
                await registry.deactivate(deactivationAmount, { from: juror })
              })

              context('when the deactivation request is for the next term', () => {
                context('when the given amount is zero', () => {
                  const amount = 0

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is lower than the active balance of the juror', () => {
                  const amount = currentActiveBalance.minus(1)

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is greater than the active balance of the juror but fits with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(1)
                  const deactivationReduced = amount.minus(currentActiveBalance)

                  itHandlesTokensCollectionFor(amount, deactivationReduced)
                })

                context('when the given amount is greater than the active balance of the juror and does not fit with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(deactivationAmount).plus(1)

                  itReturnsFalse(amount)
                })
              })

              context('when the deactivation request is for the current term', () => {
                beforeEach('increment term', async () => {
                  await registryOwner.incrementTerm()
                })

                context('when the given amount is zero', () => {
                  const amount = 0

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is lower than the active balance of the juror', () => {
                  const amount = currentActiveBalance.minus(1)

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is greater than the active balance of the juror but fits with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(1)

                  itReturnsFalse(amount)
                })

                context('when the given amount is greater than the active balance of the juror and does not fit with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(deactivationAmount).plus(1)

                  itReturnsFalse(amount)
                })
              })

              context('when the deactivation request is for the previous term', () => {
                beforeEach('increment term twice', async () => {
                  await registryOwner.incrementTerm()
                  await registryOwner.incrementTerm()
                })

                context('when the given amount is zero', () => {
                  const amount = 0

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is lower than the available balance of the juror', () => {
                  const amount = currentActiveBalance.minus(1)

                  itHandlesTokensCollectionFor(amount)
                })

                context('when the given amount is greater than the active balance of the juror but fits with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(1)

                  itReturnsFalse(amount)
                })

                context('when the given amount is greater than the active balance of the juror and does not fit with the future deactivation amount', () => {
                  const amount = currentActiveBalance.plus(deactivationAmount).plus(1)

                  itReturnsFalse(amount)
                })
              })
            })
          })
        })
      })

      context('when the sender is not the owner', () => {
        const from = anyone

        it('reverts', async () => {
          await assertRevert(registry.collectTokens(juror, bigExp(100, 18), 0, { from }), 'JR_SENDER_NOT_OWNER')
        })
      })
    })

    context('when the registry is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(registryOwner.collect(juror, bigExp(100, 18)), 'JR_SENDER_NOT_OWNER')
      })
    })
  })
})
