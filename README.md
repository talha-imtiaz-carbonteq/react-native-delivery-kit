This repository contains the automation logic, shell scripts, and pipeline configurations used to manage the mobile application lifecycle. It is split into two primary domains: End-to-End (E2E) QA automation and the core Deployment pipeline.

---

## 📂 Directory Overview

### `e2e-qa-testing-ci`
This directory houses the logic for the Appium-based testing suite. It focuses on the post-build phase, specifically how the system interacts with BrowserStack to execute mobile automation. It contains the operational scripts required to process test results, generate visual reports, and notify the engineering team of the quality status of the current build.

### `unit-tests-deployment-ci`
This directory serves as the engine for the primary GitLab CI/CD pipeline. It contains a collection of shell scripts that handle everything from initial code linting and unit testing to complex deployment decisions. This folder is responsible for determining whether a code change requires a full native binary rebuild or can be delivered instantly via an Over-the-Air (OTA) update.

---

## 📄 File Definitions & Usage

### 🧪 E2E QA Scripts (`/ops`)
* **`send_report.py`**: A Python utility that aggregates test results and sends them to stakeholders via email. 
    * *Usage:* Automatically called in the `after_script` of the E2E pipeline.
* **`README.md`**: Technical documentation specifically for the E2E reporting logic.

### 🚀 Deployment Scripts (`/scripts/ci`)
* **`run-lint.sh`**: Executes static code analysis and linting rules. 
    * *Usage:* Run during the `lint-audit` stage to ensure code style compliance.
* **`run-tests.sh`**: Triggers the Vitest/Jest unit test suite and outputs JUnit XML reports.
    * *Usage:* Run during the `test` stage to validate business logic.
* **`needs-native-build.sh`**: A logic gate that checks for changes in `package.json`, `app.json`, or native directories.
    * *Usage:* Used to set the `BUILD_TYPE` (Native vs. OTA).
* **`generate-child-pipeline.sh`**: A generator script that writes the dynamic YAML for the downstream deployment.
    * *Usage:* Called during the `decide` stage to create `child-pipeline.yml`.
* **`trigger-e2e.sh`**: A bridge script that calls the GitLab API to start the Appium QA pipeline once a build is ready.
    * *Usage:* Triggered after a successful EAS build or OTA update.
* **`run-eas-config-check.sh`**: Validates that the Expo/EAS configuration is correct before attempting a cloud build.
* **`child-pipeline.yml`**: The template/artifact used by GitLab to execute the dynamic distribution stage.
* **`build-or-ota.env`**: A storage file for environment variables passed between the parent and child pipelines.

---

## 🛠 How to Use

### 1. Local Testing
Before pushing changes to the pipeline, you can verify the logic of individual scripts locally:
```bash
# Check if your changes would trigger a native build
bash unit-tests-deployment-ci/scripts/ci/needs-native-build.sh

# Run linting manually
bash unit-tests-deployment-ci/scripts/ci/run-lint.sh
```

### 2. Pipeline Integration
To use these scripts in a GitLab CI file, reference them within your `.gitlab-ci.yml` stages:
```yaml
lint:
  script:
    - bash unit-tests-deployment-ci/scripts/ci/run-lint.sh
```

### 3. Required Environment Variables
Ensure the following variables are set in your CI environment for full functionality:
* `EXPO_TOKEN`: For EAS interactions.
* `BROWSERSTACK_USER` & `BROWSERSTACK_KEY`: For E2E testing.
* `E2E_PIPELINE_TOKEN`: For triggering downstream QA.
