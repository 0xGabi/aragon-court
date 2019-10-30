## 4.4. Voting

The `Voting` module is in charge of handling all the votes submitted by the drafted jurors and computing the tallies to ensure the final ruling of a dispute once finished. 
In particular, the first version of the Court protocol uses a commit-reveal mechanism. Therefore, the `Voting` module allows jurors to commit and reveal their votes, and leaked other jurors votes.

### 4.4.1. Constructor

- **Actor:** Deployer account
- **Inputs:**
    - **Controller:** Address of the `Controller` contract that centralizes all the modules being used
- **Authentication:** Open
- **Pre-flight checks:**
    - Ensure that the controller address is a contract
- **State transitions:**
    - Save the controller address

### 4.4.2. Create

- **Actor:** `Court` module
- **Inputs:**
    - **Vote ID:** Vote identification number 
- **Authentication:** Only `Court` module
- **Pre-flight checks:**
    - Ensure there is no other existing vote for the given vote ID
- **State transitions:**
    - Create a new vote object 

### 4.4.3. Commit

- **Actor:** Juror drafted for an adjudication round
- **Inputs:**
    - **Vote ID:** Vote identification number
    - **Commitment:** Encrypted outcome to be stored for future reveal 
- **Authentication:** Open. Implicitly, only jurors that were drafted for the corresponding adjudication round can call this function
- **Pre-flight checks:**
    - Ensure a vote object with that ID exists
    - Ensure that the sender was drafted for the corresponding dispute's adjudication round
    - Ensure that the sender has not committed a vote before
    - Ensure that votes can still be committed for the adjudication round
- **State transitions:**
    - Create a cast vote object for the sender voter

### 4.4.4. Leak

- **Actor:** External entity incentivized to slash a juror
- **Inputs:**
    - **Vote ID:** Vote identification number
    - **Voter:** Address of the voter to leak a vote of
    - **Outcome:** Outcome leaked for the voter
    - **Salt:** Salt to decrypt and validate the committed vote of the voter
- **Authentication:** Open
- **Pre-flight checks:**
    - Ensure the voter commitment can be decrypted with the provided outcome and salt values  
    - Ensure that votes can still be committed for the adjudication round
- **State transitions:**
    - Update the voter's cast vote object marking it as leaked

### 4.4.5. Reveal

- **Actor:** Juror drafted for an adjudication round
- **Inputs:**
    - **Vote ID:** Vote identification number
    - **Outcome:** Outcome leaked for the voter
    - **Salt:** Salt to decrypt and validate the committed vote of the voter
- **Authentication:** Open. Implicitly, only jurors that have committed a vote during the commit phase of the adjudication round can call this function
- **Pre-flight checks:**
    - Ensure the voter commitment can be decrypted with the provided outcome and salt values
    - Ensure the resultant outcome is valid
    - Ensure that votes can still be revealed for the adjudication round
- **State transitions:**
    - Update the voter's cast vote object saving the corresponding outcome
    - Update the vote object tally