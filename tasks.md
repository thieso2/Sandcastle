A bunch of tasks. Create a comprehensive plan how to do those - add anything that comes to mind! commit each step, write and maintan   PROGRESS.md

use subagents - always use an architect, a tester, a UI specialist and devis advocate

run stuff in chrome
use mise run deploy:local to deoploy
use docker compose -f docker-compose.local.yml logs -f to see the log
url https://sandcastle.local:8443/ <- teh CERT should be valid - we have added it to the system keychain!
thieso@gmail.com:tubu
try the cli (sancaste)

look at the ligs and fix anything obvious

clich thru the app and find any hole to fix


- Always add tests where feasible. 
- At the end create a mock for the Container Subsystem and add comprehensive tests for all UI interactions that can run in the cI

- Create a runner container for the solid-queue worker (do not run it in the puma container)

- The flash on sandcastle create and delete is never cleared (notification from the worker are probable never cleared)

- Add /jobs to monitor solid_queue jobs

- Create dummies in dev mode so this does not happen:
  ⎿  time="2026-02-13T19:29:24+01:00" level=warning msg="The \"BUILD_VERSION\" variable is not set. Defaulting to a blank string."
     time="2026-02-13T19:29:24+01:00" level=warning msg="The \"BUILD_GIT_SHA\" variable is not set. Defaulting to a blank string."
     time="2026-02-13T19:29:24+01:00" level=warning msg="The \"BUILD_GIT_DIRTY\" variable is not set. Defaulting to a blank string."
     time="2026-02-13T19:29:24+01:00" level=warning msg="The \"BUILD_DATE\" variable is not set. Defaulting to a blank string."

- run the testsuite. then use chrome and sandclastle cli to test and probe teh app, fix all bugs that you find. 

- Fix waring in traffic: 
traefik-1       | 2026-02-13T18:46:36Z WRN No domain found in rule HostRegexp(`.+`) && PathPrefix(`/terminal/5/wetty`), the TLS options applied for this router will depend on the SNI of each request entryPointName=websecure routerName=terminal-5@file

traefik-1       | 2026-02-13T18:46:36Z WRN No domain found in rule HostRegexp(`.+`), the TLS options applied for this router will depend on the SNI of each request entryPointName=websecure routerName=rails-https@file
traefik-1       | 2026-02-13T18:46:36Z WRN No domain found in rule HostRegexp(`.+`) && PathPrefix(`/terminal/3/wetty`), the TLS options applied for this router will depend on the SNI of each request entryPointName=websecure routerName=terminal-3@file


- Fix (on sandcastle delete): turbo.es2017-esm.js:668 
 GET http://localhost:8080/sandboxes/5/stats 500 (Internal Server Error)

turbo.es2017-esm.js:6746 Uncaught (in promise) Nt: The response (500) did not contain the expected <turbo-frame id="sandbox_stats_5"> and will be ignored. To perform a full page visit instead, set turbo-visit-control to reload.
    at #J (turbo.es2017-esm.js:6746:11)
    at #z (turbo.es2017-esm.js:6741:10)
    at #W (turbo.es2017-esm.js:6644:12)
    at async t.delegateConstructor.loadResponse (turbo.es2017-esm.js:6454:26)
    at async t.delegateConstructor.requestFailedWithResponse (turbo.es2017-esm.js:6537:44)

