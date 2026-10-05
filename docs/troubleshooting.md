# Troubleshooting Guide

This document records real issues encountered while improving the
`platform-engineering-cicd-pipeline` project, including what failed,
why it failed, how the issue was diagnosed, how it was fixed, and why
the final fix works.

The goal is not only to record the solution, but to understand the
reasoning behind it.

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

GitHub CLI will not overwrite an existing non-empty directory because
doing so could destroy local files or uncommitted work.

### Diagnosis

The existing project directory was already present on the machine.

Instead of cloning again, the existing Git repository could be reused.

### Resolution

The existing clone was opened and synchronized with GitHub:

    cd ~/platform-engineering-cicd-pipeline
    git checkout main
    git pull --ff-only
    git status

Git reported:

    On branch main
    Your branch is up to date with 'origin/main'.

    nothing to commit, working tree clean

### Why This Works

`git pull --ff-only` updates the local branch only when Git can move the
branch pointer directly forward to the remote commit.

It does not create an unexpected merge commit.

The clean `git status` output confirmed that the repository was in a safe
state before starting new work.

### Lesson

Before cloning a repository, check whether it already exists locally.

If it does, synchronize the existing clone instead of creating another one.

---

## 2. ECR RepositoryNotFoundException

### Symptom

The following command was used to inspect the ECR repository:

    aws ecr describe-repositories \
      --repository-names platform-engineering-cicd \
      --region eu-west-2 \
      --profile one-piece-new

AWS returned:

    RepositoryNotFoundException

The message stated that the repository did not exist in registry:

    808101329332

### Diagnosis

The active AWS identity was checked using:

    aws sts get-caller-identity \
      --profile one-piece-new

The command showed that the current AWS account was:

    808101329332

The GitHub Actions workflow was then inspected.

It still contained:

    ECR_REGISTRY: 044854092896.dkr.ecr.eu-west-2.amazonaws.com

The workflow therefore referenced a different AWS account:

    Old workflow account: 044854092896
    Current AWS account: 808101329332

A repository search in the current account also showed that
`platform-engineering-cicd` did not yet exist there.

### Root Cause

The CI/CD workflow contained stale account-specific configuration from an
older AWS environment.

Amazon ECR repositories are scoped to an AWS account and AWS region.

A repository named:

    platform-engineering-cicd

in account:

    044854092896

is a different resource from a repository with the same name in account:

    808101329332

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

The repository was configured with:

    Tag mutability: IMMUTABLE
    Scan on push: enabled
    Encryption: AES256
    Region: eu-west-2

The GitHub Actions workflow was also changed so that the ECR registry is
no longer hard-coded.

Instead, the registry is obtained from the Amazon ECR login action.

### Why This Works

The GitHub workflow now authenticates to the current AWS account and receives
the correct ECR registry directly from AWS.

This removes the dependency on a manually hard-coded AWS account ID.

The workflow is therefore less likely to silently reference an old AWS account
in the future.

### Lesson

When an AWS resource cannot be found, do not assume the resource name is wrong.

First verify:

    AWS account
    AWS region
    resource name
    active AWS CLI profile

AWS resource identity depends on more than the resource name alone.

---

## 3. Existing GitHub OIDC Provider Was Reused

### Investigation

Before creating a new GitHub OIDC provider, the AWS account was inspected:

    aws iam list-open-id-connect-providers \
      --profile one-piece-new

The account already contained:

    arn:aws:iam::808101329332:oidc-provider/token.actions.githubusercontent.com

The provider configuration was then inspected:

    aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn \
      arn:aws:iam::808101329332:oidc-provider/token.actions.githubusercontent.com \
      --profile one-piece-new

The provider contained:

    Url:
    token.actions.githubusercontent.com

    ClientIDList:
    sts.amazonaws.com

### Decision

A second GitHub OIDC provider was not created.

The existing provider was reused.

### Why This Matters

There should not be unnecessary duplicate identity infrastructure.

Checking existing state before provisioning new resources prevents:

    duplicate configuration
    unnecessary IAM objects
    confusing trust relationships
    harder future troubleshooting

### Lesson

Infrastructure work should begin with discovery of current state.

Do not create a resource simply because a tutorial or command sequence says
to create one.

First determine whether it already exists.

---

## 4. Replacing Long-Lived AWS Credentials With GitHub OIDC

### Previous Approach

The original GitHub Actions workflow authenticated to AWS using:

    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

These values were stored as GitHub repository secrets.

### Problem

AWS access keys are long-lived credentials.

If they are exposed, they remain valid until they are explicitly disabled,
deleted, or rotated.

They also create an ongoing credential-management responsibility.

### New Approach

The workflow now uses GitHub OpenID Connect.

The authentication flow is:

    GitHub Actions
          |
          v
    GitHub OIDC identity token
          |
          v
    AWS IAM trust policy
          |
          v
    STS AssumeRoleWithWebIdentity
          |
          v
    Temporary AWS credentials
          |
          v
    Amazon ECR

The workflow now has:

    permissions:
      contents: read
      id-token: write

and uses:

    role-to-assume:
      arn:aws:iam::808101329332:role/GitHubActionsPlatformCicdEcrPublisher

### What `id-token: write` Means

This permission allows GitHub Actions to request an OIDC identity token for
the workflow.

It does not mean the workflow can arbitrarily modify repository content.

The token contains identity claims that AWS can verify.

### Why This Is Safer

No permanent AWS access key needs to be stored in GitHub.

AWS STS issues temporary credentials that expire automatically.

The IAM role can also restrict which GitHub repository and branch are allowed
to request those credentials.

### Lesson

Where supported, workload identity should be preferred over stored cloud
credentials.

---

## 5. Restricting Which GitHub Workflow Can Assume the AWS Role

### Trust Policy

The IAM role uses a trust condition containing:

    repo:AZ1600/platform-engineering-cicd-pipeline:ref:refs/heads/main

The expected OIDC audience is:

    sts.amazonaws.com

### Meaning

AWS will allow the role to be assumed only when the GitHub OIDC token matches
the configured repository and branch.

The trust decision is conceptually:

    WHO may become this IAM role?

The trust policy answers that question.

### Why Main Is Restricted

The ECR publishing workflow is intended to publish trusted artifacts.

Allowing arbitrary feature branches to assume the production publishing role
would weaken that boundary.

The feature branch can develop and validate the workflow, but the real ECR
publishing path should execute from `main`.

### Important Distinction

IAM trust policy:

    WHO can assume the role?

IAM permissions policy:

    WHAT can the role do after it has been assumed?

Both layers are needed.

---

## 6. Creating a Least-Privilege ECR Publishing Policy

### Requirement

The GitHub Actions role needs to authenticate to ECR and upload container
layers.

It does not need broad administrative AWS access.

### Authorization Token Permission

The role allows:

    ecr:GetAuthorizationToken

with:

    Resource: "*"

### Why Resource Is `*`

`ecr:GetAuthorizationToken` does not support repository-level resource
restriction.

AWS therefore requires this action to use:

    Resource: "*"

This does not grant permission to publish images everywhere.

### Repository-Specific Permissions

The actual upload permissions are restricted to:

    arn:aws:ecr:eu-west-2:808101329332:repository/platform-engineering-cicd

The allowed actions are:

    ecr:BatchCheckLayerAvailability
    ecr:CompleteLayerUpload
    ecr:InitiateLayerUpload
    ecr:PutImage
    ecr:UploadLayerPart

### Security Boundary

The resulting authorization model is:

    GitHub repository
          |
          v
    main branch
          |
          v
    GitHub OIDC
          |
          v
    IAM publishing role
          |
          v
    one ECR repository

### Lesson

Least privilege means granting the workflow the actions it actually requires
against the smallest practical resource scope.

---

## 7. Removing the Hard-Coded ECR Registry

### Previous Configuration

The workflow contained:

    ECR_REGISTRY: 044854092896.dkr.ecr.eu-west-2.amazonaws.com

This tied the workflow directly to a specific AWS account.

### Problem

When the active AWS account changed, this value became stale.

The workflow continued to point toward the old account.

### New Configuration

The Amazon ECR login action now has an ID:

    - name: Login to Amazon ECR
      id: login-ecr
      uses: aws-actions/amazon-ecr-login@v2

The registry is obtained using:

    ${{ steps.login-ecr.outputs.registry }}

### Why This Works

The registry value comes from the AWS account that the workflow actually
authenticated to.

This removes duplicated account-specific configuration and reduces the risk
of configuration drift.

### Lesson

Prefer dynamically discovered infrastructure values when a trusted tool can
provide them reliably.

Avoid hard-coding cloud account information when it can be derived from the
authenticated environment.

---

## 8. Replacing the `latest` Image Tag With the Git Commit SHA

### Previous Approach

The container image was published as:

    platform-engineering-cicd:latest

### Problem

`latest` does not identify which Git commit produced the image.

It can also move over time.

That makes incident investigation and deployment traceability harder.

### New Approach

The workflow now uses:

    IMAGE_TAG: ${{ github.sha }}

An image therefore receives a tag corresponding to the Git commit that built it.

Conceptually:

    Git commit
         |
         v
    GitHub Actions workflow
         |
         v
    Docker image
         |
         v
    ECR image tagged with commit SHA

### Why This Works

The Git commit SHA is a unique identifier for the source revision used by the
workflow.

This allows engineers to trace an ECR image back to the code that produced it.

---

## 9. Why the ECR Repository Uses Immutable Tags

### Configuration

The repository was created with:

    --image-tag-mutability IMMUTABLE

### Meaning

After an image tag has been published, another image cannot overwrite that
same tag.

### Why This Matters

Suppose an image is published using commit:

    abc123

Without immutable tags, another image could theoretically later be pushed using:

    abc123

even if the image contents were different.

That would break the relationship between source revision and artifact.

Immutable tags protect the relationship:

    commit SHA
        =
    specific container artifact

### Combined With SHA Tags

Using both:

    Git commit SHA tags
    +
    ECR immutable tags

provides much stronger artifact traceability than:

    latest

---

## 10. Enabling ECR Scan on Push

### Configuration

The ECR repository was created with:

    --image-scanning-configuration scanOnPush=true

### Purpose

Amazon ECR automatically initiates an image vulnerability scan when a new image
is pushed.

### Why This Is Useful

The CI pipeline already performs Trivy container scanning before publication.

ECR scan-on-push provides an additional registry-side security signal after the
artifact reaches AWS.

These controls operate at different points:

    CI security scan
          |
          v
    image publication
          |
          v
    ECR registry scan

### Lesson

Security checks are stronger when they exist at multiple stages of the software
delivery lifecycle.

---

## 11. Verifying That Stale Credentials and Registry References Were Removed

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

### Why This Check Matters

Changing the visible workflow is not enough if stale references remain elsewhere.

Searching the repository verifies that the old authentication and registry
configuration has actually been removed from the relevant workflow files.

### Git Diff Detail

Old values may still appear in:

    git diff

as red deleted lines.

That does not mean those values still exist in the current file.

A Git diff shows both:

    removed content
    added content

The repository search checks the actual current files.

### Lesson

Understand the difference between historical diff output and the current
working-tree content.

---

# Current Secure Publishing Model

The resulting publishing flow is:

    Developer
        |
        v
    Git commit on main
        |
        v
    Manual GitHub Actions publish workflow
        |
        v
    GitHub OIDC token
        |
        v
    AWS IAM trust validation
        |
        v
    Temporary STS credentials
        |
        v
    Amazon ECR login
        |
        v
    Docker build
        |
        v
    Commit-SHA image tag
        |
        v
    Push to dedicated ECR repository
        |
        v
    Immutable artifact + ECR scan on push

The design avoids stored AWS access keys and limits the publishing identity to
the required repository, branch, AWS role, AWS region, and ECR repository.

---

# General Troubleshooting Principles Learned

Several reusable engineering lessons came from this work:

1. Inspect existing state before creating new infrastructure.
2. Verify the active AWS account and region before diagnosing missing resources.
3. Separate authentication, trust, authorization, and resource existence.
4. Prefer short-lived workload identity over stored cloud credentials.
5. Avoid unnecessary hard-coded account-specific values.
6. Use least-privilege IAM permissions.
7. Use immutable, traceable artifact identifiers instead of moving tags.
8. Validate assumptions with commands rather than relying on configuration alone.
9. Preserve troubleshooting knowledge so failures become reusable engineering lessons.
10. Understand why a fix works instead of stopping when the error disappears.
