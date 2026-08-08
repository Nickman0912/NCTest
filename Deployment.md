# Deployment.md — Technical Notes & Syntax Reference

> **Purpose:** This file documents the exact, verified CLI syntax and the technical pitfalls
> encountered while deploying the **Asset Renewal Timeline** to the `NicksPersonal` org.
> Future agents should read this BEFORE attempting a similar deploy to avoid the same
> trial-and-error. All commands below were **verified working** on this project.

---

## 1. Environment Facts (Verify First)

| Item | Value |
|---|---|
| Project root | `c:\Users\NicolasClemens\FuryDev\NCTest\NCTest` |
| Default shell | **PowerShell** (`C:\WINDOWS\system32\cmd.exe` is NOT active despite env note) |
| Salesforce CLI | Installed at `C:\Program Files\sf\bin\sf.cmd` (NOT on PATH via `npx`) |
| CLI version | `@salesforce/cli/2.123.1` (update to 2.145.6 available) |
| API version | `65.0` (project `sfdx-project.json`) |
| Target org alias | `NicksPersonal` (username `pcvnclemens@gmail.com`) |

### ⚠️ Critical: Do NOT use `npx sf` / `npx sfdx`
`npx sf --version` and `npx sfdx --version` both fail with
`npm error could not determine executable to run`. The CLI is installed globally under
`C:\Program Files\sf\bin\sf.cmd`, not as an npm package.

**Correct invocation (PowerShell):**
```powershell
& "C:\Program Files\sf\bin\sf.cmd" <command>
```

---

## 2. Verified Deployment Commands

### 2.1 Deploy the whole source directory (RECOMMENDED — most reliable)
```powershell
& "C:\Program Files\sf\bin\sf.cmd" project deploy start --source-dir force-app/main/default --target-org NicksPersonal --wait 15
```
- Result: `Status: Succeeded`.
- **Why the whole directory, not a file list:** Passing a comma-separated list
  (`--source-dir a.cls,b.cls,c.xml`) **failed** with `File or folder not found` — the CLI
  treated the entire comma string as a single path. This happened both with an unquoted
  PowerShell array and with a single-quoted string. The full-directory deploy is the only
  reliably working form.

### 2.2 Check deploy status after a timed-out / truncated deploy
If `--wait` expires mid-deploy (output is truncated, no final status), query by job id:
```powershell
& "C:\Program Files\sf\bin\sf.cmd" project deploy report --job-id <DEPLOY_ID> --target-org NicksPersonal
```
- Useful: a deploy can be reported `Succeeded` even when the terminal output was cut off.

### 2.3 Run Apex tests
```powershell
& "C:\Program Files\sf\bin\sf.cmd" apex run test --class-names AssetTimelineControllerTest --target-org NicksPersonal --wait 15 --result-format human
```

### 2.4 List orgs / confirm connectivity
```powershell
& "C:\Program Files\sf\bin\sf.cmd" org list
```

---

## 3. Syntax Pitfalls (PowerShell + CLI)

### 3.1 `&&` and `||` are INVALID in PowerShell
The default shell is PowerShell. Chaining with `&&` / `||` produces:
```
The token '&&' is not a valid statement separator in this version.
```
Use `;` to separate statements, or run individual commands.

### 3.2 `-o` is a shorthand for `--target-org`
Adding both `--target-org NicksPersonal -o` fails with:
```
Flag --target-org can only be specified once
```
Use only ONE of them.

### 3.3 `--source-dir` comma lists are unreliable
A comma-separated list of files/folders is parsed as a single path and fails with
`File or folder not found`. **Always pass a single directory** (e.g. `force-app/main/default`).

### 3.4 Invoking the CLI
Prefer the full path with `& ` (PowerShell call operator):
```powershell
& "C:\Program Files\sf\bin\sf.cmd" ...
```
Avoid `cmd /c "..."` wrapping — nested quotes around paths with spaces (e.g.
`C:\Program Files\...`) break parsing (`'C:\Program' is not recognized`).

---

## 4. Metadata / Deployment Gotchas Learned

### 4.1 `System.assertNull(String)` does NOT compile in Apex
```apex
// ❌ COMPILES BUT FAILS AT DEPLOY TIME
System.assertNull(items[0].renewalOpportunityId);
// Error: Method does not exist or incorrect signature: void assertNull(String)
```
**Fix:** assign to a local first, then assert:
```apex
String renewalId = items[0].renewalOpportunityId;
System.assert(renewalId == null, 'Expected no Renewal Opportunity linked.');
```
This triggered a **full deployment rollback** (deploy is atomic — one compile error rolls back everything).

### 4.2 `Security.stripInaccessible` silently strips fields without FLS → silent no-op
When a user lacks **field-level edit access** to a custom field, `stripInaccessible(UPDATABLE, ...)`
removes that field from the records. The DML then succeeds but the field is **not persisted**
(a silent no-op). This looked like a controller bug but was actually missing FLS.

**Symptoms:** Opportunity was created, but `Asset.Renewal_Opportunity__c` remained null.

**Fix:** Add the field permission to the project's permission set:
```xml
<fieldPermissions>
    <editable>true</editable>
    <field>Asset.Renewal_Opportunity__c</field>
    <readable>true</readable>
</fieldPermissions>
```
> Lesson: When using `stripInaccessible`, the permission set MUST grant edit access to every
> custom field the controller writes, or the writes are silently dropped.

### 4.3 Asset requires AccountId or ContactId (org validation)
Inserting an `Asset` with neither throws:
```
FIELD_INTEGRITY_EXCEPTION, Every asset needs an account, a contact, or both
```
**Fix:** Always set `AccountId` (or `ContactId`) on test Assets.

### 4.4 `AuraHandledException` message is generic in non-debug test runs
In `@isTest` (non-debug context), catching `AuraHandledException` yields a generic
`Script-thrown exception` message — NOT your custom message. So:
```apex
// ❌ Unreliable — message is generic in test context
System.assert(e.getMessage().contains('valid Account Id'), ...);
```
**Fix:** Only assert that an exception was thrown (the guard worked), not the message text:
```apex
catch (Exception e) {
    System.assert(true, 'Exception was thrown as expected.');
}
```

### 4.5 The `lookupFilter` field-metadata element caused concern
An empty `<lookupFilter>` block (no filter criteria) in a `CustomField` meta can be risky.
Simplest reliable field metadata for a lookup:
```xml
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Renewal_Opportunity__c</fullName>
    <externalId>false</externalId>
    <label>Renewal Opportunity</label>
    <referenceTo>Opportunity</referenceTo>
    <relationshipName>Renewal_Opportunities</relationshipName>
    <required>false</required>
    <trackFeedHistory>false</trackFeedHistory>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

### 4.6 LWC template: no string concatenation in `class={...}`
LWC HTML does NOT support `+` concatenation inside an expression:
```html
<!-- ❌ Invalid: LWC1058 unexpected-character-in-attribute-name -->
<div class={'tl-node ' + node.styleClass + ...}>
```
**Fix:** Precompute the full class string in JS and bind it:
```html
<div class={node.tlClass}>
```
```js
tlClass: `tl-node ${styleClass}${isLinked ? ' tl-node_linked' : ''}`,
```

### 4.7 `force:hasRecordId` is Aura — use `@api recordId` in LWC
`force:hasRecordId` is an Aura interface. In LWC the equivalent is `@api recordId` combined
with a `lightning__RecordPage` target in the `.js-meta.xml`, restricted to the object:
```xml
<targets>
    <target>lightning__RecordPage</target>
</targets>
<targetConfigs>
    <targetConfig targets="lightning__RecordPage">
        <objects><object>Account</object></objects>
    </targetConfig>
</targetConfigs>
```

### 4.8 OpportunityLineItems REQUIRE an active price book (a real org gotcha)
Adding Products to an Opportunity as `OpportunityLineItem` records requires:
1. An **active Price Book**, and
2. A **PricebookEntry** for each Product in that price book.

In this org the Standard Price Book existed but was **inactive** (`IsActive = false`), so
line-item inserts would fail. The renewal controller now:
- Activates nothing itself, but resolves the Standard/active price book Id (using
  `Test.getStandardPricebookId()` in tests), assigns `Pricebook2Id` on the Opportunity,
  **auto-creates missing PricebookEntries**, then inserts Opportunities and line items.
- One-time org setup was done via anonymous Apex (`scripts/apex/activateStandardPricebook.apex`).

**Key behaviors changed:**
- New Opportunity name pattern: `{Account Name} - Renewal - {MMM yyyy}` (earliest expiry in the group).
- One OpportunityLineItem per renewed Asset-with-Product: `Quantity = 1`, `UnitPrice = Asset.Price`.

---

## 4.9 LWC referencing a NEW StaticResource — deploy in TWO phases (RESOLVED)
> **Status:** This gotcha was encountered and fully resolved. The static resource
> (`RaptorLogo`) was later **removed** from the project entirely — the final branding uses
> the brand **feel** (colors + fonts) only, with no logo image and no "Raptor" text. The
> notes below are kept for reference in case a future component needs a static resource.

When an LWC imports a **brand-new** static resource (`@salesforce/resourceUrl/...`), the
LWC's reference validation **cannot see a resource created in the same deploy batch**.
Deploying both together fails with:
```
Invalid reference RaptorLogo of type resourceUrl in file <lwc>.js
```
Because deploys are atomic (`rollbackOnError: true`), the whole batch (including the
resource) rolls back — so the resource never lands and every retry fails the same way.

**Fix — two-phase deploy:**
1. Deploy the static resource **alone** first (its own manifest), so it exists in the org.
2. Then deploy the full source — the LWCs now validate against the existing org resource.

**Critical prerequisite:** the static resource needs its `.resource-meta.xml` on disk.
If it's missing, the CLI's source resolver can't see the resource at all, producing
`NothingToDeploy` / `ComponentSetError: No source-backed components present in the package`
on every resource-only attempt.

**Manifest approach (bypasses source-tracking diff):** after an atomic rollback, the CLI's
local tracking can desync (thinks a rolled-back component is deployed). A manifest-based
deploy (`--manifest manifest/package.xml`) builds the ComponentSet directly from the file
system and sidesteps that.

## 4.10 Brand web fonts (Google Fonts) — optional CSP Trusted Site
The rebranded components load **Source Sans Pro** and **Caveat Brush** from Google Fonts via
`loadStyle` in `connectedCallback()`, wrapped in `.catch()` so a missing CSP entry fails
silently (system font fallback). To actually render the brand fonts, add a CSP Trusted Site:
- **Setup → CSP Trusted Sites → New**
- Trusted Site Name: `Google Fonts`
- Trusted Site URL: `https://fonts.googleapis.com`
- CSP Directives: `style-src` (and `font-src` for `https://fonts.gstatic.com` if needed)

## 4.11 Branding approach — "feel" not "logo"
The three components (Asset Renewal Timeline, Asset Viewer, Relationship Hierarchy Viewer)
are branded with the Raptor **palette and typography** only — no logo image and no "Raptor"
text anywhere. This keeps the UI sleek and modern while still feeling on-brand:
- **Palette:** Raptor Orange `#faa21b`, Raptor Blue `#4e83d1`, Dark Blue `#3b5c82`,
  Navy `#233c5b`, Teal `#33a78f`, Light Blue `#d2e8ee`, Grays `#e4e4e4 / #707071 / #35353a`.
- **Fonts:** Source Sans Pro (body) + Caveat Brush (playful accent taglines like
  "Protect every child, every school, every day." and "every school, every day.™").
- **Headers:** compact gradient bands (Navy → Blue) with a subtle dot-grid texture and a
  soft orange radial accent — no hero banner, no logo.
- **JS color maps** (record types, statuses, district groups) all use the brand palette.
- The static resource (`RaptorLogo`) was removed from the project; the LWCs no longer
  import it, so a single full-directory deploy works.

## 5. Editor / Lint False Positives (do not chase these)

- **`ApexClass` meta "xml Error"**: The `.cls-meta.xml` file was byte-identical to existing
  working files. The reported XML schema error was a transient editor/index artifact, not a
  real problem — the deploy succeeded.
- **CSS errors reported against the `.html` file lines**: These were stale diagnostics from
  the missing `.css` file during creation; they cleared once the CSS file existed.
- **`jsconfig.json` `baseUrl` deprecation warning**: Pre-existing repo config, unrelated to
  this work.

---

## 6. Deployment Checklist (Reusable)

1. Confirm CLI: `& "C:\Program Files\sf\bin\sf.cmd" org list` (target org connected).
2. Deploy: `& "C:\Program Files\sf\bin\sf.cmd" project deploy start --source-dir force-app/main/default --target-org <ORG> --wait 15`.
   - On timeout, poll with `project deploy report --job-id <ID> --target-org <ORG>`.
3. Run tests: `& "C:\Program Files\sf\bin\sf.cmd" apex run test --class-names <TestClass> --target-org <ORG> --wait 15 --result-format human`.
4. Verify all metadata components report `Created`/`Changed` and tests report `100% Passed`.