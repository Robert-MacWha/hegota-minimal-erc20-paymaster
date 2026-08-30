The Hegotá EIP stack, explained

Seven EIPs that together replace Ethereum’s transaction signature with a small program, and one that decides whether the network is allowed to censor the result. This is a study guide to what each one does, why it exists, and how they lean on each other.
The one idea everything hangs off

An ordinary Ethereum transaction proves who sent it with a single ECDSA signature. The protocol checks that signature, charges the sender for gas, and runs the call. Authentication is fixed, and the person who authenticates is always the person who pays.

Frame transactions replace that signature with a sequence of small execution steps called frames. Instead of the protocol verifying a signature, the transaction carries code that runs on-chain and calls an opcode, APPROVE, to say “yes, this is authorised, and here is who pays.”

Once authentication is a program rather than a fixed algorithm, three things fall out that were previously impossible:

    Any verification scheme works. A passkey, a multisig, a social-recovery rule, a zero-knowledge proof. If you can express it in EVM code, it can authorise a transaction.
    The sender and the payer can differ. One account proves identity, a different account settles the gas bill. This is what people mean by “sponsored” or “paymaster” transactions, done natively instead of bolted on.
    Several operations become one atomic unit. Approve a token and swap it in a single transaction that either fully happens or fully does not.

Everything else in this document is either an extension of that idea, a piece of plumbing it needs, or a rule about how the network is permitted to treat the result.
Naming

Hegotá is the fork name on the execution side. The consensus side calls the same fork heze. They activate at the same moment; you will see both names in configs and they are not two things.
How they fit together

The eight EIPs are not a flat list. There is a base, a set of extensions that widen it, a separate axis about censorship resistance, and a layer of pre-existing machinery they all stand on.
THE GROUND · already in Amsterdam 7928 block access lists · 8037 two-dimensional gas · 7843 slot number EIP-8141 · Frame Transactions the base: type 0x06, frames, APPROVE EIP-8250 keyed nonces EIP-8272 recent roots EIP-7906 tx assertions EIP-8312 UTXO frames EIP-7805 · FOCIL forced inclusion, anti-censorship EIP-8369 · eligibility which omissions are enforceable constrains
Solid boxes activate together at Hegotá. Dashed boxes are scheduled separately or not yet binding. The FOCIL pair runs on a different axis: it does not extend frame transactions, it limits what a block builder is allowed to leave out.

Read it in four groups:

    The base. EIP-8141 defines the new transaction type. Nothing else in the stack means anything without it.
    The extensions. 8250, 8272 and 7906 each add a field or a frame kind to that base. 8312 does too, but on its own schedule.
    The other axis. 7805 and 8369 are about censorship, not authentication. They say what a builder must include and what happens when it does not.
    The ground. 7928, 8037 and 7843 already shipped in the previous fork. The stack borrows their machinery rather than reinventing it.

EIP-8141 Base · activates at Hegotá
Frame Transactions

The problem: a transaction’s signature check is hard-coded, and whoever signs must also pay. The fix: a new transaction type whose authentication is a small program you supply.
What a frame transaction looks like

It is transaction type 0x06. Where a normal transaction has v, r, s, this one has a list of frames:

0x06 || rlp([chain_id, nonce, sender, frames, signatures,
             max_priority_fee_per_gas, max_fee_per_gas,
             max_fee_per_blob_gas, blob_versioned_hashes])

each frame = [mode, flags, target, gas_limit, value, data]

A frame is one execution step. It has its own gas limit and its own target, and the mode byte says what role it plays:
Mode	Name	What it is for
0	DEFAULT	Ordinary execution. Also used for a “deploy” frame that installs code at the sender.
1	VERIFY	Authentication. Runs before anything else and must call APPROVE.
2	SENDER	The actual work, run as the sender.
3	POST_TX	Added by EIP-7906. Checks the result afterwards.
5	UTXO	Added by EIP-8312 on this branch. Spends a payment object.
The validation prefix, and why it matters everywhere else

The leading VERIFY frames are called the validation prefix. This is the part that establishes two facts before any real work happens: that the transaction is authorised, and who the payer is.

The prefix must match one of exactly four recognised shapes. This restriction is not cosmetic; it is what lets a node reason about an unfamiliar transaction cheaply.
Shape	Meaning
self_verify	One VERIFY frame. The sender authorises and pays for itself.
deploy | self_verify	Same, but first installs the sender’s verification code.
only_verify | pay	One frame authorises, a second frame gets a sponsor to pay.
deploy | only_verify | pay	Both of the above.

Remember the prefix. Nearly every hard question later in this document is really a question about it: how much gas it is allowed to burn, what state it is allowed to read, and whether a validator can afford to re-run it.
The opcodes it adds
Byte	Opcode	Does what
0xAA	APPROVE	Declares the transaction authorised, and collects the payer’s maximum possible cost up front.
0xB0	TXPARAM	Reads a field of the transaction envelope.
0xB1–0xB2	FRAMEDATALOAD / COPY	Reads the current frame’s data.
0xB3	FRAMEPARAM	Reads a field of a frame.
0xB4	SIGPARAM	Reads the supplied signature material.
Detail worth holding on to

APPROVE charges the payer the maximum cost, max_gas × max_fee_per_gas, not the eventual actual cost. The difference comes back as a refund after execution. Any shortcut that estimates the real cost instead will declare a payer solvent who then reverts in practice. This exact mistake was found and removed from a draft spec; see EIP-8369 below.
Receipts change too

One frame transaction produces one receipt containing a receipt per frame, plus the payer’s address. So you can see that frame 1 succeeded, frame 2 reverted, and frame 3 never ran, all inside one transaction.
EIP-8250 Extends 8141 · activates at Hegotá
Keyed Nonces

The problem: one account has one nonce counter, so its transactions must execute in a strict line. The fix: give an account many independent counters.

A nonce stops replay attacks by forcing transaction n+1 to follow transaction n. That is fine for a personal wallet, and painful for anything shared. A sponsor paying for thousands of users, or a contract acting for many people, has one counter and therefore one queue: everything serialises behind everything else.

EIP-8250 replaces the single nonce field with two:

nonce_keys : 1..16 strictly increasing uint256   // which counters
nonce_seq  : u64                                 // the value they must all be at

Each key is its own independent replay domain. Two transactions from the same sender on disjoint key sets have no ordering relationship at all and can be included in either order, or simultaneously.
Where it lives	Detail
Key 0	The account’s ordinary nonce. Backwards compatible.
Any other key	Stored in the NONCE_MANAGER predeploy at 0x…8250.
Slot formula	keccak256(pad32(sender) || pad32(key))
Extra cost	A one-off charge the first time a given key is used.

Note the address convention, which recurs: a predeploy for EIP-N lives at 0x…N. It makes the constants self-documenting.
EIP-8272 Extends 8141 · activates at Hegotá
Recent Roots

The problem: verification code often needs to check a proof against a recent commitment, but reading another contract’s mutable storage during validation is dangerous. The fix: declare the commitment in the signed envelope instead.

Consider a privacy protocol. To spend, you prove membership in a Merkle tree whose root lives in some contract’s storage. Your validation code needs that root.

Reading it directly creates a problem the whole network feels. That storage slot is shared: it changes whenever anyone else uses the protocol. So a single change can invalidate every pending transaction that read it at once, which is exactly the mass-invalidation behaviour a mempool cannot tolerate.

EIP-8272 lets the transaction carry the roots it depends on, as signed data:

recent_root_references : [ (source_id, slot, root), ... ]   // up to 16

The protocol validates these against the RECENT_ROOT_ADDRESS predeploy at 0x…8272, which keeps a ring buffer of recent commitments. A reference is valid while its slot is within roughly the last 8191 slots. Validation code reads its own envelope with RECENTROOTREFLOAD (0xB5) and never touches shared storage.
Why the ring buffer is bounded

Roots expire so the predeploy’s storage cannot grow forever. Roughly 8191 slots is about a day. Long enough that a transaction sitting in the mempool stays valid, short enough that the state stays bounded.
EIP-7906 Extends 8141 · activates at Hegotá
Transaction Assertions

The problem: you cannot tell what a transaction actually did until it is already mined. The fix: attach a check that runs afterwards and can undo the work.

A wallet simulates a transaction, sees a fair-looking swap, and submits it. Between simulation and inclusion the world moves, and what lands is worse. Or a contract sneaks in a token approval the user never intended.

EIP-7906 adds POST_TX frames (mode 3): trailing frames that run read-only after the transaction body, can inspect everything it did, and can revert it.

Three opcodes let them see the result:
Byte	Opcode	Reads
0xB6	TXTRACE	Gas context and execution facts.
0xB7	EVENTDATACOPY	Events the transaction emitted.
0xB8	TXDIFF	The state changes it made, per address.
The subtle part

A POST_TX revert reverts the body, not the transaction. The transaction is still included, gets status = 0, and the payer is still fully charged. The validation prefix stays committed. That is the correct behaviour: the authentication really did happen and consumed real work, so it is paid for even though the intended effect was rolled back.
EIP-8312 Extends 8141 · separate schedule
UTXO Frames

The problem: paying someone who has no account yet costs a permanent account entry in the world state. The fix: a one-shot payment object that leaves almost nothing behind.

Ethereum uses accounts. Bitcoin uses UTXOs: discrete coins that are created once and spent once. EIP-8312 adds a UTXO-shaped payment primitive alongside the account model.

You deposit to a vault at 0x…8312 naming a recipient. The protocol assigns an index and, at the end of the block, commits that block’s creations into a Merkle root. Spending is a new frame mode that runs no EVM code at all: the frame carries Merkle proofs, and the protocol checks them, flips an irreversible spent bit, and pays out.
Flow	Gas	Permanent state left behind
Create one payment object	36,334	none
Spend it	56,094	one spent bit
Full cycle	92,428	~0.3 bytes
Plain transfer to a fresh account	204,600	~120 bytes

So the complete create-and-spend cycle is about 2.2× cheaper in gas than a single ordinary transfer to a new account, and hundreds of times cheaper in permanent state. The state gap matters more than the gas gap, because under two-dimensional gas it is the state dimension that fills a block first.

The value is concentrated rather than general. This is a payments primitive, strongest for one-shot, high-volume payouts to recipients who do not exist on chain yet. It is not a replacement for accounts.
EIP-7805 Consensus axis · FOCIL
Fork-Choice Enforced Inclusion Lists

The problem: a block builder can quietly refuse to include your transaction forever. The fix: let a committee publish a list of transactions the next block must contain.

Everything above this point is about the execution layer. FOCIL is about the consensus layer, and it answers a different question: not “is this transaction valid” but “is the network allowed to ignore it”.

Each slot, a committee of 16 includers each publish an inclusion list. The next block builder is expected to include those transactions. Attesters check afterwards, and a builder that left one out without a good reason does not get their votes.

“Without a good reason” is the whole design. An omission is excused when the transaction genuinely could not have been added: it would not fit in the remaining gas, its nonce is wrong, its balance is too low. Those checks are cheap for ordinary transactions, which is why FOCIL works today.
The collision

Frame transactions break that assumption. Their validity depends on running a program, so “could this have been included?” is no longer a cheap arithmetic check. Every attester would have to re-execute somebody else’s validation code, for every omitted transaction, before the attestation deadline. Resolving that is what the next EIP is for.
EIP-8369 Consensus axis · informational
VOPS Profiles for FOCIL Eligibility

The problem: checking whether a frame transaction was unfairly excluded could cost more work than validators can afford. The fix: only enforce the subset that is cheap enough to check.

The answer is to sort transactions into profiles. If a transaction fits a profile, its omission is enforceable. If it does not, it can still be listed and included, but nobody is punished for leaving it out.
Profile	Covers	Omission judged
1 · Base	Ordinary transactions, no blobs	At the end of the block, as FOCIL already does.
2 · AA-VOPS	Frame transactions inside a fixed state surface	At a position in the block the builder names.
—	Everything else, including anything with blobs	Never. Always excused.
The three limits that make it affordable

A bounded state surface. A qualifying validation prefix may read the sender’s and payer’s balance and nonce, and only their first few storage slots, a count called AA_VOPS_SLOT_COUNT. Reading anything else does not make the transaction expensive, it makes it ineligible. That numeric bound is also what excludes mapping entries, whose slots are keccak hashes and therefore enormous numbers.

A gas budget. Each transaction may declare at most 220 gas of validation work, and each inclusion list may hold 220 in total. Across 16 includers that is about 16.8M gas of replay per slot, roughly 28% of a 60M block. The EIP states that figure and openly flags that it is not yet a settled number.

A named index. Instead of forcing builders into a quadratic “try appending at every position” loop, the builder simply commits to a position and attesters check there. If the builder names nothing, the default is the end of the block.
What the index costs you

The party choosing the block contents also chooses the state the transaction is judged against. So the guarantee only fully holds for transactions whose validity is position-stable, meaning it cannot be flipped by reordering. Single-use nonces qualify. A shared sponsor’s balance does not: another sponsored transaction can drain it first. The EIP accepts this openly rather than papering over it.

EIP-8369 is Informational, which means it describes the model but binds nobody. Actual enforcement needs a further Standards Track EIP that does not exist yet, and AA_VOPS_SLOT_COUNT has no agreed value.
EIP-7928 · 8037 · 7843 The ground · already shipped
The machinery underneath

These arrived in the previous fork. The stack leans on them heavily, and several things above only make sense once you know they exist.
EIP-7928 — Block Access Lists

Every block carries a structured record of the state it touched: which accounts, which storage slots, what changed. It was built for parallel execution and stateless clients. FOCIL reuses it for something else entirely: reconstructing what the world looked like at a given position inside a block, which is exactly what judging an omission at a named index requires.
EIP-8037 — Two-dimensional gas

Gas splits into an execution dimension and a state-growth dimension, each with its own limit. This is why EIP-8312’s tiny state footprint matters so much: a block runs out of state room before it runs out of compute, so the cheap-in-state option raises real throughput rather than just saving fees.
EIP-7843 — Slot number

The execution layer can read the current consensus slot. EIP-8272’s expiry window is expressed in slots, so recent roots depend directly on this.
One transaction, end to end

Here is a sponsored, passkey-authenticated, privacy-preserving payment that uses five of the eight at once. Follow the ordering, because the ordering is the design.

type 0x06 frame transaction
  nonce_keys  [0x9f3a…]        ← 8250: an independent replay lane
  recent_root_references [(…)] ← 8272: the commitment its proof needs

  frame 0  VERIFY  only_verify   ← the validation prefix
  frame 1  VERIFY  pay             establishes authorisation + payer
  ──────────────────────────────
  frame 2  SENDER                ← the body: the actual transfer
  frame 3  POST_TX               ← 7906: check nothing unexpected happened

    Before any code runs, the protocol checks the keyed nonces (8250) and validates the recent-root references (8272). Both are decided up front, not during execution.
    Frame 0 verifies the passkey signature. It reads its proof material from the envelope with RECENTROOTREFLOAD, never from shared storage, so no other user’s activity can invalidate it.
    Frame 1 runs the sponsor’s logic and calls APPROVE. The sponsor is now the payer and is charged the maximum possible cost.
    Frame 2 does the real work as the sender.
    Frame 3 inspects the finished result with TXDIFF. If an invariant broke, it reverts frame 2 — but frames 0 and 1 stay committed and the sponsor still pays.
    Separately, FOCIL (7805) may have listed this transaction. Whether a builder can be punished for omitting it is decided by 8369: frames 0 and 1 must fit the bounded state surface and the gas budget.

Notice that the validation prefix, frames 0 and 1, is doing three jobs at once. It authenticates, it decides who pays, and it is the thing FOCIL has to be able to afford to re-run. Every difficult constraint in the stack lands on those two frames.
What this branch changes

These are all draft EIPs, so parts collide or are simply blank. hegota-devnet records every place it had to decide something the specs do not settle.
Where	Spec says	This branch does	Why
UTXO frame mode	3	5 	EIP-7906 already shipped mode 3 for POST_TX. Renumbering would invalidate signed transactions and every tool that makes them.
AA_VOPS_SLOT_COUNT	unset, “2 to 4, pending benchmarks”	4, as a config value 	Top of the range is the worst case for validator work, so a result that passes at 4 passes at 2 and 3. Configurable so the range can be measured.
Storage rule when a node does both jobs	silent	Whichever check is running picks its own rule 	The mempool rule and the FOCIL rule overlap without either containing the other. Raised upstream as an open question.
NONCEKEYLOAD at 0xB9	no such opcode	added 	EIP-8250 defines no way to read an individual nonce key. This is an ethrex-only convenience.

Two of these are worth understanding as a pattern rather than trivia. The mode 3 collision happens because two draft EIPs picked the same byte without a shared registry. The blank AA_VOPS_SLOT_COUNT happens because the spec author correctly refused to guess a number that needs measurement. Both are the ordinary texture of implementing drafts, and writing the decision down is what keeps the divergence honest.
How it switches on

Almost everything here activates together at the Hegotá fork, using one timestamp. Two things do not.
Feature	Switch	Notes
8141, 8250, 8272, 7906	hegotaTime	One fork, all at once. Also called heze on the consensus side.
8312 UTXO frames	utxoFramesTime	Its fork assignment is undecided upstream, so it gets its own switch and stays completely inert until a chain opts in.
7805 FOCIL	hegotaTime	Same fork, but it is the one feature that is not purely execution-layer.
The one that bites

Every other feature here is invisible to the consensus client: it schedules the fork and the execution layer does the rest. FOCIL is different. It needs a consensus client that builds and gossips inclusion lists and calls new engine methods. So turning FOCIL on means upgrading both layers at the same moment, with no working state in between. That, rather than any of the code, is the real obstacle to running it.
A useful habit

Giving a feature its own future timestamp, rather than folding it into a fork, means every block already produced re-executes identically. A running chain can adopt the feature without starting over. That is why EIP-8312 could be added to a live devnet, and it is a technique worth reaching for whenever a change is not yet certain.
