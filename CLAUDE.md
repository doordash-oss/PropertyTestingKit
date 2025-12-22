## Building
- Do not build this project with system swift. Use the build script found in the scripts directory. It builds this project using a patched swift toolchain that fixes issues with parameter packs.

## Debugging
- Use LLDB interactively instead of print debugging when it will speed up the process.

## Testing
- We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
- When targeting 100% coverage, target 100% branch coverage. If branches are difficult or impossible to reach, either rework code to remove the need for them, or use dependency injection to achieve the necessary state. Force unwrapping is not a solution.  

### Benchmarks
- The filter flag for benchmarks requires that you match the entire name of the benchmark you want to run. Partial matches will not work, and may appear to hang.

## Scripts
- If you find yourself performing operations frequently, add a script to the scripts directory.
- If one of those scripts stops working, fix it.



