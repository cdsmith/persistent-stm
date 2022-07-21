# Correctness of `persistent-stm`

A particularly clever library such as this one demands a solid argument in favor
of its correctness.  This document gives the reasons for my belief that the
library is sound and provides the guarantees that it claims, as well as the
wekanesses in that reasoning.

## Overall approach

The core mechanism taken by `persistent-stm` for writing data is to maintain,
using STM itself, a "dirty set" of persistent `DBRef` values that need to be
written to persistent storage, and to write them from a background thread after
the STM transaction that made the modification has been committed.  This part of
the library is straight-forward and not too hard to follow.  The complexity
arises on the read side of the fence.

Since writes to persistent storage happen asynchronously after an STM
transaction has completed, a read that immediately follows the transaction may
not necessarily produce the correct data.  To handle this, `persistent-stm`
maintains the following properties:

1. There is only one `TVar` per key in memory at any time, holding its
   associated value.  A lookup table of weak pointers is used to ensure that as
   long as that `TVar` is reachable, the data from that `TVar` is used instead
   of data in persistent storage.
2. When there is a pending write for a key, its unique `TVar` is intentionally
   kept reachable by including it in the dirty set.  This ensures that data from
   persistent storage can never be used while there still a pending write for
   the key.

We'd like to say that this ensures a successful transaction only ever sees a
consistent set of values across the entire database.  For this to be true, we
need additional assumptions: first, that the data is consistent when the program
starts, and second, that the only way for the persistent storage to change while
the program is running is for a write to happen within this process using the
dirty set.   This is why `persistent-stm` cannot work with multiple processes
concurrently accessing the persistent storage, even if only one of them is
writing.

# Correctness of `unsafeIOToSTM`

There are several uses of `unsafeIOToSTM` in `persistent-stm`, which deserve
additional scrutiny.  There are four ways in which `unsafeIOToSTM` can be
unsafe:

1. The IO action may run multiple times if they are retried.
2. The IO action may leak inconsistent data from inside a transaction through
   side effects that are not undone when the transaction is aborted.
3. The IO action may see mutable state that is not tracked by STM, so that the
   transaction isn't retried even after the state changes.
4. The IO action may be aborted without an opportunity to clean up resources.

This package uses `unsafeIOToSTM` to read from persistent storage, dereference
weak pointers, and allocate new weak pointers.  Only the last has any side
effect at all: adding a finalizer for the new weak pointer.  That finalizer
checks for and removes stale entries from the lookup table, but it is written to
be idempotent and safe to run at any time.  If there is no stale entry, it
simply does nothing.  Therefore, we need not worry about duplicating side
effects, nor leaking inconsistent state through side effects.

Addressing the third variety of potentially unsafe use of `unsafeIOToSTM`, our
actions may observe mutable state in two ways.  Most fundamentally, reading from
persistent storage obviously gains access to the contents of that storage.
Here, though, we rely on the reasoning above that persistent storage only
changes when it is written via the dirty set.  For that to happen, some other
completed transaction must have the unique `TVar` associated with that key.  In
that case, the transaction reading from persistent storage will already be
retried: it wasn't able to find that `TVar` in the cache, but the `TVar` is now
in the cache, so the cache itself must have changed and will cause the necessary
retry.

A second form of mutable state that is observed is in weak pointers:
Dereferencing a weak pointer observes whether the value referred to has been
garbage collected.  However, dereferencing this weak pointer only occurs
immediately after, and in the same atomic action with, looking it up in the
cache.  If the value is garbage collected, resulting in a change to the observed
state, this will *also* cause the associated finalizer to run, which will remove
the stale entry from the cache.  That change to the cache itself will trigger a
retry of transactions that previously looked up the weak pointer.

This leaves us with the last way in which use of `unsafeIOToSTM` can be unsafe:
the IO action may be aborted without an opportunity to clean up resources.  For
the read from persistent storage, it's certainly possible that this will involve
resources that need to be cleaned up.  For this reason, the read doesn't happen
in the STM thread at all.  Instead, `unsafeIOToSTM` is used to fork a new thread
that performs the read.  An `MVar` is used to communicate the result from this
new thread back to the STM thread.  If the STM thread is interrupted, then the
IO thread will continue to run, cleaning up after itself as usual, but will
write its result to an `MVar` that will never be read.  While unnecessary, this
is still correct.

The actions actually performed inside `unsafeIOToSTM`, then, are these: creating
an `MVar`, forking a new thread, waiting for the `MVar` to be filled, creating a
weak pointer, and referencing a weak pointer.  The `MVar` here is created empty,
written once from the IO thread, and read once from the STM thread, so aborting
the STM thread will simply leave a dead `MVar` with a value that will never be
read, which isn't a problem.  Similarly, when creating and dereferencing weak
pointers, the resulting values are only used back in the STM monad.   The
remaining danger is that something in these operations holds a lock or other
resource who abandonment will corrupt the *global* state of the process.
Admittedly, it's difficult to be certain they won't do so, but we also have no
reason to believe that they do.

# Conclusion

This argument should establish that, except for certain unspecified details, the
approach to persistence taken by `persistent-stm` is sound.

The argument also shed light on ways in which the approach is limited.  In
particular:

1. We rely on the safety of using `forkIO`, `newEmptyMVar`, `takeMVar`,
   `mkWeak`, and `deRefWeak` inside of `unsafeIOToSTM` without potentially
   corrupting global process state.  This is an assumption, but I feel a
   reasonable one.
2. We rely deeply on the assumption that there are no writers to persistent
   storage outside of `persistent-stm` itself.  Violating this assumption may
   not only cause inconsistent data, but may even cause deadlock and other
   problems.
