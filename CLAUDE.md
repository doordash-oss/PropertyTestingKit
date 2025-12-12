Use LLDB interactively instead of print debugging when it will speed up the process.
Do not use live dependencies during tests.
We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
If you find yourself performing operations frequently, add a script to the scripts directory.
If one of those scripts stops working, fix it.
When targeting 100% coverage, target 100% branch coverage. If branches are difficult or impossible to reach, either rework code to remove the need for them, or use dependency injection to achieve the necessary state. Force unwrapping is not a solution.  
Do not build this project with system swift. Use the build script found in the scripts directory. It builds this project using a patched swift toolchain that fixes issues with parameter packs.

