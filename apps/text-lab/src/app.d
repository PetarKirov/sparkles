/// The text lab's desktop entry; the command line is `cli`'s.
module app;

import cli : run;
import sparkles.base.driver_libc : reexecOntoDriverGlibc;

int main(string[] args)
{
    // Before anything opens a driver: run on the drivers' glibc when theirs
    // is newer than the one this program was built with (Linux only).
    reexecOntoDriverGlibc();
    return run(args);
}
