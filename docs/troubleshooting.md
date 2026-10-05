# Troubleshooting Guide

This document records real issues encountered while improving the
`platform-engineering-cicd-pipeline` project.

For each issue, the goal is to capture:

- what failed
- what evidence was observed
- how the problem was diagnosed
- the root cause
- how it was fixed
- why the fix works
- what engineering lesson can be reused elsewhere

---

## 1. GitHub CLI Clone Failed Because the Repository Already Existed

### Symptom

Running:

    gh repo clone AZ1600/platform-engineering-cicd-pipeline

returned:

    fatal: destination path 'platform-engineering-cicd-pipeline'
    already exists and is not an empty directory

### Root Cause

The repository had already been cloned locally.

GitHub CLI does not overwrite an existing non-empty directory because doing so
could destroy local files or uncommitted work.

### Diagnosis

The existing repository was opened directly and checked with Git:

    cd ~/platform-engineering-cicd-pipeline

    git checkout main
    git pull --ff-only
    git status

Git reported that the local branch was synchronized with `origin/main`.

### Resolution

The existing clone was reused rather than cloning another copy.

### Why This Works

`git pull --ff-only` updates the branch only when Git can move it directly
forward without creating an unexpected merge commit.

A clean working tree provides a safe starting point for new work.

### Lesson

Before cloning a repository, first determine whether a local copy already
exists.

---

## 2. ECR RepositoryNotFoundException

### Symptom

Running:

    aws ecr describe-repositories \
      --repository-names platform-engineering-cicd \
      --region eu-west-2 \
      --profile one-piece-new

returned:

    RepositoryNotFoundException

AWS reported that the repository did not exist in registry:

    808101329332

### Diagnosis

The current AWS identity was checked:

    aws sts get-caller-identity \
      --profile one-piece-new

The active AWS account was:

    808101329332

The GitHub Actions workflow contained:

    044854092896.dkr.ecr.eu-west-2.amazonaws.com

The account IDs did not match.

### Root Cause

The workflow contained stale account-specific configuration from an older AWS
environment.

Amazon ECR repositories are scoped by:

    AWS account
    AWS region
    repository name

A repository with the same name in another AWS account is a different resource.

### Resolution

A new ECR repository was created in the current AWS account:

    aws ecr create-repository \
      --repository-name platform-engineering-cicd \
      --region eu-west-2 \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --profile one-piece-new

The resulting repository was:

    808101329332.dkr.ecr.eu-west-2.amazonaws.com/platform-engineering-cicd

It was configured with:

    Region: eu-west-2
    Tag mutability: IMMUTABLE
    Scan on push: enabled
    Encryption: AES256

### Why This Works

The repository now exists in the AWS account actually being used by the
pipeline.

The workflow was also changed so the registry is discovered dynamically rather
than being hard-coded.

### Lesson

When an AWS resource appears to be missing, verify:

    account
    region
    active CLI profile
    resource name

before assuming the resource itself is broken.

---

## 3. Existing GitHub OIDC Provider Was Reused

### Investigation

Before creating a GitHub OIDC provider, the current AWS account was inspected:

    aws iam list-open-id-connect-providers \
      --profile one-piece-new

An existing provider was found:

    arn:aws:iam::808101329332:oidc-provider/token.actions.githubusercontent.com

It was inspected with:

    aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn \
      arn:aws:iam::808101329332:oidc-provider/token.actions.githubusercontent.com \
      --profile one-piece-new

The provider used:

    token.actions.githubusercontent.com

with audience:

    sts.amazonaws.com

### Decision

The existing provider was reused.

### Why This Matters

Creating unnecessary duplicate identity infrastructure can cause:

    confusing trust relationships
    duplicated configuration
    harder troubleshooting
    unnecessary IAM resources

### Lesson

Inspect existing infrastructure before provisioning new infrastructure.

---

## 4. Replacing Long-Lived AWS Credentials With GitHub OIDC

### Previous Approach

The workflow originally used:

    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY

stored as GitHub repository secrets.

### Problem

Access keys are long-lived credentials.

If exposed, they remain usable until manually rotated, disabled, or deleted.

### New Approach

The publishing workflow now uses GitHub OpenID Connect.

The authentication flow is:

    GitHub Actions
          |
          v
    GitHub OIDC token
          |
          v
    AWS IAM trust policy
          |
          v
    STS AssumeRoleWithWebIdentity
          |
          v
    temporary AWS credentials
          |
          v
    Amazon ECR

The workflow requests:

    permissions:
      contents: read
      id-token: write

and assumes:

    arn:aws:iam::808101329332:role/GitHubActionsPlatformCicdEcrPublisher

### Why This Is Safer

No permanent AWS credential needs to be stored in GitHub.

AWS STS credentials expire automatically.

The IAM trust relationship can also restrict exactly which GitHub repository
and branch are allowed to assume the role.

### Lesson

Prefer short-lived workload identity over stored cloud credentials.

---

## 5. Restricting Which GitHub Workflow Can Assume the AWS Role

### Trust Policy

The IAM role trust policy restricts the GitHub identity to:

    repo:AZ1600/platform-engineering-cicd-pipeline:ref:refs/heads/main

The OIDC audience is:

    sts.amazonaws.com

### Meaning

The trust policy answers:

    WHO may become this IAM role?

Only a workflow from the intended repository and `main` branch should satisfy
the trust condition.

### Why This Matters

Feature branches should not automatically receive permission to publish trusted
artifacts to the production ECR repository.

### Important Distinction

IAM trust policy:

    WHO can assume the role?

IAM permissions policy:

    WHAT can the role do after assumption?

Both controls are required.

---

## 6. Creating a Least-Privilege ECR Publishing Policy

### Requirement

The GitHub Actions publishing role needs permission to:

- authenticate to Amazon ECR
- upload image layers
- publish an image manifest
- later retrieve the stored image digest

It does not require broad AWS administrative access.

### Authorization Token Permission

The role allows:

    ecr:GetAuthorizationToken

with:

    Resource: "*"

This action cannot be restricted to an individual ECR repository.

### Repository-Scoped Permissions

The actual ECR operations are restricted to:

    arn:aws:ecr:eu-west-2:808101329332:repository/platform-engineering-cicd

The publishing actions include:

    ecr:BatchCheckLayerAvailability
    ecr:CompleteLayerUpload
    ecr:DescribeImages
    ecr:InitiateLayerUpload
    ecr:PutImage
    ecr:UploadLayerPart

### Why This Is Least Privilege

The role can authenticate to ECR but can only publish and inspect image
metadata for the intended repository.

### Lesson

Grant only the actions required and scope them to the smallest practical
resource boundary.

---

## 7. Removing the Hard-Coded ECR Registry

### Previous Configuration

The workflow contained:

    ECR_REGISTRY: 044854092896.dkr.ecr.eu-west-2.amazonaws.com

### Problem

This tied the workflow directly to an old AWS account.

When the AWS account changed, the workflow silently retained stale
configuration.

### New Configuration

The workflow uses the output from:

    aws-actions/amazon-ecr-login

The registry is obtained through:

    steps.login-ecr.outputs.registry

### Why This Works

The registry value comes from the AWS account that the workflow actually
authenticated to.

### Lesson

Prefer deriving cloud resource identifiers from authenticated runtime context
rather than duplicating account-specific configuration.

---

## 8. Replacing `latest` With Git Commit SHA Tags

### Previous Approach

Images were published using:

    latest

### Problem

`latest` does not identify which source revision produced an image.

It can also change over time.

### New Approach

The workflow uses:

    ${{ github.sha }}

For example:

    ebdc23381190227e46d84259be746b106c33b19c

### Why This Works

The image tag now identifies the exact Git commit that produced the artifact.

The traceability path becomes:

    Git commit
        |
        v
    GitHub Actions run
        |
        v
    container image
        |
        v
    ECR image tag

### Lesson

Use immutable, traceable identifiers for release artifacts.

---

## 9. Why the ECR Repository Uses Immutable Tags

### Configuration

The repository was created with:

    --image-tag-mutability IMMUTABLE

### Meaning

Once an image tag has been published, a different image cannot later replace
the same tag.

### Why This Matters

If a tag representing a Git commit could be overwritten, the relationship
between source and artifact would no longer be trustworthy.

Using:

    Git commit SHA tags
    +
    ECR immutable tags

creates a stronger relationship between source revision and container artifact.

---

## 10. Enabling ECR Scan on Push

### Configuration

The ECR repository uses:

    scanOnPush=true

### Purpose

ECR performs registry-side vulnerability scanning after an image is uploaded.

### Relationship to CI Scanning

The pipeline also performs Trivy scanning before publication.

The controls operate at different stages:

    CI Trivy scan
        |
        v
    publish image
        |
        v
    ECR scan on push

### Lesson

Layering security checks provides better coverage than depending on a single
scanner or stage.

---

## 11. Verifying Stale AWS References Were Removed

### Verification

The repository was searched for:

    044854092896
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    :latest

using:

    grep -R -E \
      '044854092896|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|:latest' \
      .github \
      --exclude-dir=.git \
      -n

The check returned:

    No stale AWS credential, registry, or latest-tag references found

### Important Git Detail

Deleted values can still appear in red inside:

    git diff

because a diff shows historical lines being removed.

That does not mean the value still exists in the current file.

### Lesson

Differentiate between:

    current working-tree contents

and:

    historical diff output

when validating configuration cleanup.

---

## 12. Trivy CI Failed Because the Digest-Pinned Base Image Became Vulnerable

### Symptom

Pull-request validation failed at:

    Scan container image for vulnerabilities

Earlier steps passed:

    Dockerfile lint
    Docker image build

Trivy exited with code `1`.

### CI Security Policy

The workflow scans using:

    --severity HIGH,CRITICAL
    --ignore-unfixed
    --exit-code 1

This means fixed HIGH or CRITICAL vulnerabilities block the workflow.

### Diagnosis

The same Trivy scan was reproduced locally.

The findings came from operating-system packages inherited from the container
base image, including packages such as:

    util-linux
    pcre2

The application code itself was not the source.

The Dockerfile used:

    nginxinc/nginx-unprivileged:1.30.4-alpine

pinned by digest.

### Root Cause

Digest pinning freezes the exact dependency tree.

That provides reproducibility, but it also means security patches are not
automatically received.

The pinned NGINX/Alpine image had become stale relative to current
vulnerability intelligence and patched upstream packages.

### Investigation

A newer official image was tested:

    nginxinc/nginx-unprivileged:1.30.5-alpine3.24

It was scanned independently using the same Trivy policy.

The result was:

    Vulnerabilities: 0

for the blocking HIGH/CRITICAL gate.

### Resolution

The Dockerfile was updated to the newer official image and pinned to its
multi-platform digest.

The application image was rebuilt.

### Security Validation

The rebuilt project image produced:

    Vulnerabilities: 0

for the blocking Trivy policy.

### Runtime Validation

The updated image was also checked for runtime compatibility:

    UID 101 verified
    GID 101 verified

It was started with:

    read-only root filesystem
    cap-drop ALL
    no-new-privileges
    restricted tmpfs

The application remained operational.

### Smoke Test

The HTTP endpoint returned:

    Platform Engineering CI/CD Pipeline

and:

    Application smoke test passed

### Why the Security Gate Was Not Weakened

The failure was not solved by:

    disabling Trivy
    lowering severity
    removing --exit-code 1
    ignoring the CVEs

The vulnerable dependency was replaced instead.

### Lesson

Digest pinning and vulnerability scanning solve different problems.

A secure process needs:

    pin dependencies
        +
    continuously scan dependencies
        +
    deliberately refresh them when fixes become available

---

## 13. ECR Push Succeeded but Workflow Failed While Parsing the Image Digest

### Symptom

The publishing workflow successfully completed:

    GitHub OIDC authentication
    ECR login
    Docker build
    CycloneDX SBOM generation
    SBOM validation
    SBOM artifact upload

It then failed during:

    Push Docker image to Amazon ECR

### Important Observation

The actual ECR push succeeded.

Docker reported:

    b75bebb0271e866ff688b1380daac768b8093586:
    digest: sha256:e864467c713b29c2994fb4a9b2f6fde5f2c8fc161ece938915d28a5bcee7e153
    size: 2404

The workflow failed after publication while extracting the digest.

### Original Parsing Logic

The workflow used:

    docker push "$IMAGE_URI" 2>&1 | tee push-output.txt

and:

    awk '/digest:/ {print $2; exit}'

### Root Cause

The parser assumed:

    digest: sha256:<digest> size: <size>

but Docker actually returned:

    <git-sha>: digest: sha256:<digest> size: <size>

Therefore:

    $1 = <git-sha>:
    $2 = digest:
    $3 = sha256:<digest>

The workflow extracted:

    digest:

instead of the SHA-256 value.

The digest validation correctly rejected the bad value.

### Why `$3` Was Not Used as the Final Fix

Changing `$2` to `$3` would have fixed this particular output format.

However, the workflow would still depend on parsing human-readable Docker
console output.

The digest is security-sensitive because it becomes the subject of artifact
attestations.

### Stronger Resolution

After pushing, the workflow now asks Amazon ECR directly:

    aws ecr describe-images \
      --repository-name "$ECR_REPOSITORY" \
      --image-ids imageTag="$IMAGE_TAG" \
      --region "$AWS_REGION" \
      --query 'imageDetails[0].imageDigest' \
      --output text

The result must match:

    ^sha256:[0-9a-f]{64}$

before it is used.

### Eventual Consistency Handling

The workflow retries the ECR lookup several times with short delays.

This protects against a short delay between the completed push and image
metadata becoming queryable through the ECR API.

### IAM Change

The publishing role gained:

    ecr:DescribeImages

scoped only to:

    arn:aws:ecr:eu-west-2:808101329332:repository/platform-engineering-cicd

### Why This Fix Is Better

The new flow is:

    Docker push
        |
        v
    Amazon ECR
        |
        v
    ECR DescribeImages API
        |
        v
    authoritative image digest
        |
        v
    SHA-256 validation
        |
        v
    provenance and SBOM attestations

### Important Side-Effect Lesson

The GitHub job showed failure even though the image was already present in ECR.

A failed automation job does not imply that all earlier external side effects
were rolled back.

### Lesson

For security-sensitive artifact metadata, prefer authoritative service APIs
over parsing human-oriented command output.

---

## 14. `gh run list` Returned the Previous Workflow Run

### Symptom

A new publishing workflow was created successfully:

    gh workflow run ci.yml --ref main

GitHub immediately returned a new run ID:

    37329944685

A command was then used to rediscover the newest run:

    gh run list \
      --workflow=ci.yml \
      --branch main \
      --limit 1

That query briefly returned the previous failed run:

    37328465217

The terminal therefore showed:

    has already completed with 'failure'

even though the newly created run was different.

### Root Cause

There was a short timing window between creating the workflow dispatch event
and the new run becoming the first result returned by `gh run list`.

The workflow itself was not failing.

This was a run-discovery race.

### Diagnosis

The exact run ID printed by:

    gh workflow run

was used directly:

    gh run watch 37329944685 --exit-status

That returned:

    completed with 'success'

### Resolution

For manually dispatched workflows, prefer the exact run ID or URL returned at
creation time rather than immediately rediscovering it through a list query.

### Lesson

Automation tooling can have eventual-consistency behaviour too.

When a command returns the exact identifier of a newly created resource, use
that identifier directly.

---

## 15. Successful End-to-End SBOM and Provenance Validation

### Final Workflow

The completed publishing workflow ran from commit:

    ebdc23381190227e46d84259be746b106c33b19c

The complete workflow succeeded:

    Checkout repository
    Configure AWS credentials with GitHub OIDC
    Login to Amazon ECR
    Build Docker image
    Generate CycloneDX SBOM
    Validate SBOM
    Upload SBOM artifact
    Push Docker image to Amazon ECR
    Generate build provenance attestation
    Generate SBOM attestation

### CycloneDX SBOM

The generated SBOM was successfully validated and contained:

    71 components

The uploaded GitHub Actions artifact was named:

    sbom-ebdc23381190227e46d84259be746b106c33b19c

### Published Image Digest

Amazon ECR reported the authoritative image digest:

    sha256:2373ce5dd52054f67b2ee81eff4028c09daf7c092e85baedbbd5f1c47753b260

### Build Provenance

A build provenance attestation was created for:

    808101329332.dkr.ecr.eu-west-2.amazonaws.com/platform-engineering-cicd@sha256:2373ce5dd52054f67b2ee81eff4028c09daf7c092e85baedbbd5f1c47753b260

GitHub attestation ID:

    52871120

### SBOM Attestation

An SBOM attestation was created for the same immutable image digest.

GitHub attestation ID:

    52871128

### Signing

The attestations were signed using the public Sigstore infrastructure.

The signatures were also recorded in the Rekor transparency log.

### What This Proves

The project can now answer several separate supply-chain questions.

Who authenticated to AWS?

    A trusted GitHub Actions workflow using OIDC.

What source revision produced the image?

    The Git commit SHA used as the ECR image tag.

What exact artifact was published?

    The immutable ECR SHA-256 digest.

What is inside the image?

    The CycloneDX SBOM.

Where did the artifact come from?

    The build provenance attestation.

Can the attestation be independently verified?

    The signed GitHub attestation and transparency-log record provide evidence.

---

# Current Secure Publishing Model

The final publishing path is:

    Git commit on main
            |
            v
    GitHub Actions
            |
            v
    GitHub OIDC token
            |
            v
    AWS IAM trust validation
            |
            v
    AWS STS temporary credentials
            |
            v
    Amazon ECR authentication
            |
            v
    Container build
            |
            +--------------------+
            |                    |
            v                    v
    CycloneDX SBOM         container artifact
                                 |
                                 v
                         immutable SHA tag
                                 |
                                 v
                            Amazon ECR
                                 |
                                 v
                     authoritative digest
                                 |
                    +------------+------------+
                    |                         |
                    v                         v
             build provenance           SBOM attestation
                attestation
                    |                         |
                    +------------+------------+
                                 |
                                 v
                        signed supply-chain
                              evidence

---

# General Troubleshooting Principles Learned

1. Inspect existing state before creating new infrastructure.
2. Verify AWS account and region before diagnosing missing resources.
3. Separate authentication, trust, authorization, and resource existence.
4. Prefer short-lived workload identity over stored cloud credentials.
5. Avoid unnecessary hard-coded account-specific configuration.
6. Use least-privilege IAM permissions.
7. Use immutable and traceable artifact identifiers.
8. Treat vulnerability scanning as a continuously changing security signal.
9. Do not weaken a working security gate merely to make CI green.
10. Validate runtime behaviour after changing container dependencies.
11. Prefer authoritative APIs over parsing human-oriented output.
12. Remember that failed workflows may already have changed external systems.
13. Account for eventual consistency when automating cloud APIs.
14. Use exact resource IDs returned by creation commands when possible.
15. Preserve troubleshooting knowledge so future failures become easier to solve.
16. Understand why a fix works instead of stopping when the error disappears.
