# 🚀 GitLab CI – Appium Test Pipeline (Android + iOS)

This pipeline is responsible for running **Appium tests on BrowserStack real devices** for both **Android** and **iOS**.
It is designed to be **triggered automatically by Expo Webhooks** after a new app build is created.

The workflow ensures:

* Per-platform isolation
* Efficient caching (pnpm + puppeteer)
* Correct BrowserStack app upload behavior
* Optional auto-submission to Expo (disabled by default)

---

## 🧭 Pipeline Flow Overview

1. **Expo Webhook triggers a pipeline** → sends `EXPO_BUILD_URL` + metadata.
2. Pipeline creates **two parallel jobs** (Android + iOS).
3. Each job:

   * Installs dependencies
   * Downloads chrome for Puppeteer
   * Checks if build already exists on BrowserStack
   * Uploads the build (only if missing)
   * Runs smoke or regression tests
4. HTML test reports are saved per platform.
5. Optional: Expo auto-submission (commented out).

---

## 🛠️ What This Pipeline Does

### ✔ Runs Appium tests for:

* **Android**
* **iOS**

### ✔ Ensures BrowserStack 1-parallel limit

Using `resource_group: browserstack_${PLATFORM}`
→ Prevents Android and iOS from fighting over the single parallel session.

### ✔ Smart BrowserStack Upload

Each build is fingerprinted using:

```
MD5(EXPO_BUILD_URL) → short fingerprint
```

Then mapped to:

```
propwire_<platform>_<fingerprint>
```

If BrowserStack already has this custom_id → **reuse the previously uploaded app**.
If not → upload the build automatically.

This prevents:

* Duplicate uploads
* Errors from repeated uploads

---

## ⚙️ Trigger Logic (When Jobs Run)

| Trigger Source                                | Android Job Runs? | iOS Job Runs? | Condition                 |
| --------------------------------------------- | ----------------- | ------------- | ------------------------- |
| Expo webhook with `EXPO_PLATFORM=android`     | ✅                 | ❌             | Only android build tested |
| Expo webhook with `EXPO_PLATFORM=ios`         | ❌                 | ✅             | Only iOS build tested     |
| Expo webhook with `EXPO_PLATFORM= "" or null` | ✅                 | ✅             | Test both (fallback)      |

This is controlled by:

```yaml
parallel:
  matrix:
    - PLATFORM: ["android", "ios"]
```

and the `rules:` conditions.

---

## 🔧 Required CI Variables

| Variable              | Purpose                                  |
| --------------------- | ---------------------------------------- |
| **BROWSERSTACK_USER** | Auth for BrowserStack API                |
| **BROWSERSTACK_KEY**  | Auth for BrowserStack API                |
| **EXPO_BUILD_URL**    | URL of the built APK/IPA file            |
| **EXPO_PLATFORM**     | "android" or "ios"                       |
| **TEST_TYPE**         | `smoke` (default) or `regression`        |
| **AUTO_SUBMISSION**   | Enable submission after successful tests |
| **EXPO_TOKEN**        | Required if submission is enabled        |

---

## 📁 Directory Structure for Reports

After tests:

```
android/html-reports/
ios/html-reports/
```

These folders are uploaded as GitLab artifacts and kept for **1 week**.

---

## ▶️ How to Manually Trigger Tests

Go to:

```
CI/CD → Run Pipeline
```

Set:

```
EXPO_BUILD_URL = (build .apk / .ipa URL)
EXPO_PLATFORM = android / ios / "" 
TEST_TYPE = smoke / regression
```

Then run.
If `EXPO_PLATFORM` is empty → both platforms run.

---

## 🔍 How BrowserStack Upload Logic Works

### Step 1: Generate fingerprint

```
md5sum(EXPO_BUILD_URL) → short 10-char fingerprint
```

### Step 2: Create custom_id

```
propwire_<platform>_<fingerprint>
```

### Step 3: Check if uploaded

Query:

```
https://api-cloud.browserstack.com/app-automate/recent_apps
```

If exists → reuse.
If not → upload.

This ensures:

* No duplicated app uploads
* Stable reference for each unique build
* Predictable test pipeline behavior

---

## ⚡ Testing Logic Per Platform

| Platform | Smoke Test                | Regression Test                |
| -------- | ------------------------- | ------------------------------ |
| Android  | `pnpm test:android:smoke` | `pnpm test:android:regression` |
| iOS      | `pnpm test:ios:smoke`     | `pnpm test:ios:regression`     |

---

## 📤 Optional: Expo Auto-Submission

Submission block exists but is commented out:

```yaml
# npx eas-cli submit --platform "$PLATFORM" --url "$EXPO_BUILD_URL"
```

Enable only if:

* Tests pass
* `AUTO_SUBMISSION=true`
* `EXPO_TOKEN` is set

---

## 🛠️ Modifying or Extending the Pipeline

### Enable submissions

Uncomment the section under `# EXPO AUTO SUBMISSION IS DISABLED`.

### Run only regression tests

Set in CI Variables:

```
TEST_TYPE=regression
```

### Skip iOS testing

Use:

```
EXPO_PLATFORM=android
```

### Change parallel behavior

Remove parallel matrix to run platform one by one:

```yaml
parallel: 1
```




