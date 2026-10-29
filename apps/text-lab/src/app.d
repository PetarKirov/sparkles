/// The text lab's desktop entry; the command line is `cli`'s.
module app;

import cli : run;

int main(string[] args) => run(args);
