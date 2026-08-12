# Flow YAML — directory layout, `OpenFlow` shape, `input_transforms` inside `value:`, `wmill flow push`'s arg shape, and quote `expr:` that contain `{`

Gotchas that bit sessions porting or deploying a flow:

## 0. A flow is a `<name>.flow/` **directory** containing `flow.yaml` — not a bare `<name>_flow.yaml` file

The wmill CLI's `DOTTED_SUFFIXES` table is unambiguous:

```js
DOTTED_SUFFIXES = { flow: ".flow", app: ".app", raw_app: ".raw_app" };
METADATA_FILES  = { flow: { yaml: "flow.yaml" }, ... };
```

A flow is recognised by `path.endsWith("/flow.yaml") && path.includes(".flow/")`. The same shape as raw_apps:

```
✅ f/engineering/example_demo.flow/flow.yaml     ← deploys
❌ f/engineering/example_demo_flow.yaml          ← silently ignored by `wmill sync push`
❌ f/engineering/example_demo.flow.yaml          ← also silently ignored (the `.flow` must be a directory suffix, not a file suffix)
```

The failure mode is **silent**: `wmill sync push` doesn't warn, doesn't error, doesn't list the file in its change set. The flow simply isn't there on the workspace. The first version of `f/engineering/example_demo.flow/flow.yaml` shipped as `example_demo_flow.yaml` and the deploy succeeded ("17 changes pushed") but the flow itself was nowhere in the diff. `f/cs/escalation_flow.yaml` has the same shape and also doesn't sync — it's a stray YAML file the CLI doesn't recognise as anything.

### How to verify

After `wmill sync push --dry-run` (or in a successful CI deploy log), the diff section should list your flow as one of the changes:

```
+ flow f/<team>/<name>
~ flow f/<team>/<name>
```

If your flow file doesn't appear, the CLI didn't see it — fix the directory layout, not the YAML contents.

### Inline rawscripts inside flows ≠ inline runnables inside raw_apps

Flows use the `RawScript` schema directly under `value:`:

```yaml
# Inside a flow's value.modules[*].value
type: rawscript
language: bun
content: |
  export async function main() { ... }
input_transforms: { ... }
```

Raw_apps use a different shape (`type: inline` + `inlineScript: { language, content }` nested), per `claude/rules/raw-app-inline-runnable-yaml.md`. Don't cross-pollinate — neither shape works in the other context.

## 1. `input_transforms` lives inside `value:`, not at the FlowModule level

The Windmill CLI's `OpenFlow` schema (find it in `/opt/homebrew/lib/node_modules/windmill-cli/esm/main.js`, search `FlowModuleValue`) puts `input_transforms` on each `FlowModuleValue` variant — `PathScript.input_transforms`, `RawScript.input_transforms`, etc. `FlowModule` itself only carries `id`, `value`, `summary`, `retry`, `cache_ttl`, `suspend`, `mock`, `stop_after_if`, `skip_if`, `sleep`, `timeout`, `continue_on_error`, `priority`. **`input_transforms` is not a FlowModule field.**

Correct:

```yaml
value:
  modules:
    - id: greet
      value: # ← FlowModuleValue (RawScript / PathScript)
        type: script
        path: f/engineering/example_greeting
        input_transforms: # ← inside value:
          recipient:
            type: javascript
            expr: flow_input.recipient
      retry: { constant: { attempts: 2, seconds: 1 } } # ← FlowModule-level (sibling to value:)
      cache_ttl: 60 # ← FlowModule-level
```

Wrong (this is what `f/cs/escalation_flow.yaml` does — it predates the convention):

```yaml
modules:
  - id: greet
    value:
      type: script
      path: f/engineering/example_greeting
    input_transforms: # ← WRONG, FlowModule level
      recipient:
        type: javascript
        expr: flow_input.recipient
```

The new canonical reference flow is **`f/engineering/example_demo.flow/flow.yaml`** — copy from that, not `escalation_flow.yaml`.

The same nesting rule applies inside `forloopflow.modules[*].value` (the inline `RawScript` there carries its own `input_transforms`). The `failure_module` follows the same `FlowModule` shape — `id: failure` + `value: { type: rawscript, ..., input_transforms: {...} }`.

## 2. Quote `JavascriptTransform.expr` strings that contain `{` or `[`

A bare YAML scalar that starts with `Array.from({ length: ... }, ...)` or `{ a: b, c: d }` is parsed as a YAML flow mapping/sequence, not as a string. YAML emits:

```
yaml.scanner.ScannerError: mapping values are not allowed here
```

…and points at the colon inside the JS object literal. Quote the whole expression:

```yaml
# ✅ Correct
iterator:
  type: javascript
  expr: "Array.from({ length: flow_input.repeat }, (_, i) => i + 1)"

# ❌ Wrong — YAML eats the `{` as flow-mapping syntax
iterator:
  type: javascript
  expr: Array.from({ length: flow_input.repeat }, (_, i) => i + 1)
```

Rule of thumb: if your `expr:` value contains any of `{ } [ ] , :` outside a string literal, quote it. Single-quote it if the expression contains double quotes; double-quote it otherwise.

## 3. `wmill flow push`'s `file_path` arg is the `.flow/` directory, not `flow.yaml` itself

`wmill flow push <file_path> <remote_path>` unconditionally appends `/flow.yaml` to `file_path` (`windmill-cli@1.700.1`, `pushFlow`: `if (!localPath.endsWith(SEP)) localPath += SEP; ... yamlParseFile(localPath + "flow.yaml")` — no check for a trailing `flow.yaml`, unlike `flow preview`, which does strip one). Pass the file itself and the CLI looks for a doubled path and fails:

```
Error parsing yaml f/engineering/example_demo.flow/flow.yaml/flow.yaml
```

```bash
# ✅ Correct — the .flow directory
wmill flow push f/engineering/example_demo.flow f/engineering/example_demo

# ❌ Wrong — the flow.yaml file inside it
wmill flow push f/engineering/example_demo.flow/flow.yaml f/engineering/example_demo
```

`scripts/classify-grid-paths.sh` emits the directory for this reason — if you're hand-rolling a `wmill flow push` call (e.g. testing from your laptop per `local-windmill-dev.md`), pass the directory too.

## How to verify

```bash
python3 -c "import yaml; yaml.safe_load(open('f/<team>/<flow>.yaml'))" && echo OK
```

If it parses, then check shape:

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('f/<team>/<flow>.yaml'))
for m in d['value']['modules']:
    v = m['value']
    if 'input_transforms' in m:
        print(f'WRONG: {m[\"id\"]} has input_transforms at FlowModule level — move it inside value:')
    if v.get('type') in ('script', 'rawscript') and 'input_transforms' not in v:
        if v.get('type') == 'script':
            print(f'NOTE: {m[\"id\"]} (script) has no input_transforms — fine only if the target takes no params')
"
```

There is no CI check for flow YAML shape today. `wmill sync push` accepts the wrong placement silently (the input is just ignored, and the step runs with empty args). If a third flow drifts here, that's the trigger to add `scripts/check-flow-shape.sh`.
