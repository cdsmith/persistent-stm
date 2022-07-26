# persistent-stm - STM transactions involving persistent storage

[![CI](https://github.com/cdsmith/persistent-stm/actions/workflows/ci.yml/badge.svg)](https://github.com/cdsmith/persistent-stm/actions/workflows/ci.yml)
[![Hackage](https://img.shields.io/hackage/v/persistent-stm)](https://hackage.haskell.org/package/persistent-stm)

Haskell's `STM` monad implements composable transactions on in-memory state,
offering atomicity, isolation, and consistency.  However, they lack persistence,
so changes are not durable at all.  This package adds a limited form of
persistence to the existing STM monad, allowing for transactions that include
writing values durably to external storage.

The persistence is limited in the following senses:

* First, it is only suitable for use by a single process at a time.  It is not
  possible to access the storage from multiple processes at the same time,
  *even* *if* some of those processes are merely readers.
* While the view of data in memory is always consistent, the consistency of data
  on disk depends on the `Persistence` implementation, which you choose.  The
  included implementation, `filePersistence`, does *not* guarantee that data
  will be in a consistent or readable state if the process is suddenly
  terminated with a power outage, system crash, etc.  This can be fixed by using
  a `Persistence` implementation built on a transactional storage layer such as
  a database.
* Consistency is not guaranteed between the different persistent storage if
  multiple `DB`s are used in the same program.

The persistence essentially works as a key-value store.  The key is a `String`,
and the value can be of any type that implements `DBStorable`.  The `DBStorable`
class works like `Binary` or other serialization classes, except that it's
designed to have access to the `DB` so that it can contain other `DBRef`s.  This
way, at runtime, you can maintain complex data structures that point directly to
each other, but are persisted via their keys.

# Quick Start

A simple example of using `persistent-stm` follows:

```haskell
import PersistentSTM.DB

main :: IO ()
main = do
    persistence <- filePersistence "./my-data"
    withDB persistence $ \db -> do
        n <- atomically $ do
            ref <- getDBRef db "my-key"
            readDBRef ref >>= \case
                Nothing -> do
                    writeDBRef ref 1
                    return 1
                Just n -> do
                    writeDBRef ref (n + 1)
                    return (n + 1)
        putStrLn $ "Number of times program was run: " ++ show n
```

Here, `filePersistence` creates a `Persistence` implementation that stores data
in a directory called `./my-data` on disk.  The `withDB` function brackets the
portion of code that uses the directory for storage.  During the execution of
`withDB`, one can use `db` to read and write persistent values inside of STM
transactions.  That is done using `getDBRef`, `readDBRef`, `writeDBRef`, and
`deleteDBRef`.

# FAQ

## Does this work reliably?

I'm publishing this now to get more feedback, but I am confident that within the
limitations described above, this is a correct implementation.  Until there is a
broader community consensus, I'll still label this experimental.

## How does this compare with the TCache package?

The implementation here was inspired by TCache, and involves some similar ideas.
I was motivated to implement this package because of several details in which
use of TCache was hard to justify.  These include:

* Playing too fast and loose with unsafe operations for my taste.
* Far too much use of global state and overlapping instances.
* Many more possible states making it hard to reason about the correctness of
  the implementation.
* Failure to build with newer GHC versions.

All things put together, I reached the conclusion that I could trust a new
implementation more than TCache.

Note that TCache has more features that this package.  I don't intend to
implement features like triggers, indexes, and so on, all of which can be
implemented on top of the basic functionality in this package if desired.
