Use LLDB interactively instead of print debugging when it will speed up the process.
Do not use live dependencies during tests.
We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
If you find yourself performing operations frequently, add a script to the scripts directory.
If one of those scripts stops working, fix it.
