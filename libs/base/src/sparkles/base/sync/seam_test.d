/**
Tests of the wait seam: oracle 3 (native behaviour) and oracle 5 (injected
faults, the macOS fallback) for SYF1–SYF4 and SYK8.
*/
module sparkles.base.sync.seam_test;

import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.seam;

static if (hasNativeSeam)
{
    @("sync.seam.SYF1.returnsWhenValueDiffers")
    @safe nothrow @nogc
    unittest
    {
        shared uint word = 1;
        assert(wait(word, 0, Deadline.never) == SeamResult.woken);
    }

    @("sync.seam.SYF4.pastDeadlineReturnsAtOnce")
    @safe nothrow @nogc
    unittest
    {
        shared uint word = 0;
        const before = seamFaults.waits;
        assert(wait(word, 0, Deadline(MonoTime.currTime.ticks - 1)) == SeamResult.timedOut);
        assert(seamFaults.waits == before + 1);
    }

    @("sync.seam.SYF4.deadlineInTheNearFuture")
    @safe nothrow @nogc
    unittest
    {
        shared uint word = 0;
        const start = MonoTime.currTime;
        auto d = Deadline.at(start + 2.msecs);
        SeamResult r;
        // A spurious return is allowed; the deadline must eventually report.
        while ((r = wait(word, 0, d)) == SeamResult.woken) {}
        assert(r == SeamResult.timedOut);
        assert(MonoTime.currTime - start >= 2.msecs);
    }

    @("sync.seam.SYF1.wakeReleasesAWaiter")
    @system
    unittest
    {
        import core.atomic : atomicLoad, atomicStore;

        shared uint word = 0;
        shared bool released;
        auto t = new Thread({
            while (atomicLoad(word) == 0)
                cast(void) wait(word, 0, Deadline.never);
            atomicStore(released, true);
        });
        t.start();
        Thread.sleep(1.msecs);
        atomicStore(word, 1);
        wake(word, WakeCount.all);
        t.join();
        assert(atomicLoad(released));
    }

    @("sync.seam.SYK8.wakeOfAFreedAddressIsHarmless")
    @system
    unittest
    {
        import core.stdc.stdlib : free, malloc;

        auto p = cast(shared(uint)*) malloc(uint.sizeof);
        free(cast(void*) p);
        wakeAddress(p, WakeCount.one);
        wakeAddress(p, WakeCount.all);
    }

    @("sync.seam.oracle5.injectedFaultsReturnAtOnce")
    @safe nothrow @nogc
    unittest
    {
        shared uint word = 0;
        seamFaults.spuriousReturns = 1;
        seamFaults.interruptedReturns = 1;
        assert(wait(word, 0, Deadline.never) == SeamResult.woken);
        assert(wait(word, 0, Deadline.never) == SeamResult.woken);
        assert(seamFaults.spuriousReturns == 0 && seamFaults.interruptedReturns == 0);
    }

    version (OSX)
    {
        @("sync.seam.SYF3.selectionIsCachedAndUlockRuns")
        @system
        unittest
        {
            const first = darwinMechanism();
            assert(first != DarwinSeam.unresolved);
            assert(darwinMechanism() == first);
            scope (exit)
                cast(void) resolveDarwin(false);
            assert(resolveDarwin(true) == DarwinSeam.ulock);
            shared uint word = 0;
            auto d = Deadline.at(MonoTime.currTime + 1.msecs);
            SeamResult r;
            while ((r = wait(word, 0, d)) == SeamResult.woken) {}
            assert(r == SeamResult.timedOut);
            assert(wait(word, 1, Deadline.never) == SeamResult.woken);
        }

        @("sync.seam.SYF4.subNanosecondRemainderSleeps")
        @system
        unittest
        {
            // A deadline one tick away has a positive remainder below 1 ns on a
            // fast clock; the call must still sleep (at least 1 ns), not hang.
            foreach (forceUlock; [false, true])
            {
                cast(void) resolveDarwin(forceUlock);
                shared uint word = 0;
                auto d = Deadline(MonoTime.currTime.ticks + 1);
                SeamResult r;
                while ((r = wait(word, 0, d)) == SeamResult.woken) {}
                assert(r == SeamResult.timedOut);
            }
            cast(void) resolveDarwin(false);
        }
    }
}
