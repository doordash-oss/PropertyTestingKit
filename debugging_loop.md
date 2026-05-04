Very important: lldb is the best tool you have at your disposal and in most cases it will better help you understand control flow and program state than print debugging. It should be your first choice for exploration.

You are going to do the following:
1. Look in DEBUGGING_PROGRESS.md if it exists. If it doesn't exist, create it. If it's missing any information you already have about the problem at hand, ammend that.
2. Do not try to solve the problem right away. You must complete Dewey's five phases of reflective inquiry:
  1. FELT DIFFICULTY — What specifically failed? Describe the gap between expected and actual behavior, not just the error name.
  2. PROBLEM DEFINITION — Narrow the problem. What precise condition or assertion was violated? Where in the system does the fault lie?
  3. HYPOTHESIS — What do you believe is the root cause? State it as a falsifiable claim.
  4. REASONING — If your hypothesis is correct, what specific evidence would you expect to observe? What evidence would DISPROVE it?
  5. TESTING — Gather empirical evidence to confirm or refute your hypothesis. Do not skip this step. Do not rely solely on reading code — static reading cannot reveal runtime state, execution order, or interaction effects. Approaches to gather evidence include:
     - Write a minimal test that isolates the behavior and reproduces the failure
     - Use a debugger (lldb mcp) to inspect actual runtime state at the point of failure
     - Add targeted logging or assertions to confirm your predicted state
     - Research: read docs, search for known issues, check recent changes to the area
     - Read source code (weakest — prefer the above when control flow or state is involved)
  Report your findings for each phase.
3. When you feel you've learned something new, update DEBUGGING_PROGRESS.md. Discuss what worked and what diddn't work.
4. Only then can you attempt to solve the problem if you feel like you know enough to do so. Continue to update DEBUGGING_PROGRESS.md with the results of your attempt.
5. If you still don't know enough or you haven't found a solution, return.
