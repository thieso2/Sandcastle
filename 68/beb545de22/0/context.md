# Session Context

## User Prompts

### Prompt 1

sandcastle route  set hello hase.de 

{"time":"2026-02-12T16:06:06.780395523Z","level":"INFO","msg":"Request","path":"/api/sandboxes","status":200,"dur":234,"method":"GET","req_content_length":0,"req_content_type":"application/json","resp_content_length":365,"resp_content_type":"application/json; charset=utf-8","remote_addr":"192.168.107.1:52504","user_agent":"Go-http-client/1.1","cache":"miss","query":"","proto":"HTTP/1.1"}
[eaf5973e-cd06-412b-bb36-3939cdce3ac3] Started POST "/api/sandboxes/7/r...

### Prompt 2

~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % ./sandcastle route  list hello
DOMAIN     PORT  URL
hase.de    8080  https://hase.de
2.hase.de  8080  https://2.hase.de

~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % ./sandcastle route  delete hello 2.hase.de
API error (404): <!doctype html>

<html lang="en">

  <head>

    <title>The page you were looking for doesn't exist (404 Not found)</title>

[8f7bceb7-546c-4548-be07-d135308324ee] Started DELETE "/api/sandboxes/7/ro...

### Prompt 3

commit this

