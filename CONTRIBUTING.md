# Contribution Policy

Copyright 2026, Spark Software Development, LLC.

Read [LICENSE.MD](LICENSE.MD) and the [Spark Contribution Agreement 1.1.0](#spark-contribution-agreement-110) before preparing a change. The standard licence and the contribution agreement are separate grants. The agreement gives you limited permission to prepare, test and submit a contribution, and sets out the rights you grant when you submit it.

Rubotty also includes the Rubotty Deployment Addendum 1.0.0 in [LICENSE.MD](LICENSE.MD). It permits unmodified non-commercial instances, requires written permission for commercial or enterprise operation, and separately prohibits charging community users for Rubotty features or charging communities to use an instance. General commercial permission does not waive either prohibition. These deployment terms preserve the limited contribution, review and controlled testing permissions below, and do not retroactively replace earlier grants or separate written agreements.

Open a focused pull request against this repository. Explain the problem, what changes and how you checked it. Include a small reproduction when fixing a bug, add tests for important behavior, and keep unrelated changes separate. Keep source and project documentation clear and factual.

Do not submit credentials, private data, build output or material you cannot license. Identify any third-party code, data or assets, their sources and their licences, and keep their notices intact. You remain responsible for checking the work you submit and for having any employer or other permission needed to contribute it. Temporary test builds for identified reviewers are allowed only under the controlled testing permission below.

**You keep ownership, but Spark may use and commercially relicense your submitted contribution, including under proprietary terms, even if it is declined or withdrawn.** Read that grant before accepting it.

For an external contribution, include this completed block in the pull request, or with a contribution submitted by another route. Replace every placeholder and check the acknowledgement only for yourself or a grantor you are authorized to represent:

```
<!-- contribution-agreement:start -->
Contribution agreement: Spark Contribution Agreement 1.1.0
- [ ] I have read and accept the Spark Contribution Agreement 1.1.0 in CONTRIBUTING.md, and I have the rights needed to submit this contribution under it.
Grantor: REPLACE_WITH_INDIVIDUAL_OR_LEGAL_ENTITY
Authority: REPLACE_WITH_OWN_RIGHTS_OR_REPRESENTATIVE_AUTHORITY
Covered submission: REPLACE_WITH_PULL_REQUEST_OR_PATCH_AND_REVISION_SCOPE
Preparation began: YYYY-MM-DD
Third-party material: REPLACE_WITH_NONE_OR_SOURCE_AND_LICENCE_AND_RESTRICTIONS
<!-- contribution-agreement:end -->
```

Identify the individual or legal entity granting the rights, your authority to act for it, the pull request or patch covered, and the date preparation began. Each contributor must acknowledge the agreement, or an authorized representative must identify the contributions and rights its acknowledgement covers. An added contributor needs the same coverage. Later revisions remain subject to the agreement and your rights confirmations; identify changes to the grantors or third-party material. Do not publish private employer paperwork or personal contact details in the pull request; arrange a private maintainer channel if evidence is needed.

Complete the third-party field with `none`, or identify the material, source, licence and any restrictions affecting the intended licensing model. Maintainers verify the grant and its revision coverage before integrating an external contribution. They retain a private record of the agreement version and exact policy bytes, the actual acknowledgement and grantor authority, covered source revisions, disclosures, extensions and resulting release. An automated check or another person's statement cannot accept the agreement for you.

Spark's first-party maintenance, for which Spark already holds the necessary rights, does not require a contribution licence to itself. Use the separate block below instead of a contributor acknowledgement. A trusted maintainer must verify the authorization and covered work; CI must not accept an outside contributor's self-declared maintenance claim as a substitute for the external grant. This records a rights basis, not agreement acceptance. Use only one block for a submission.

```
<!-- contribution-maintenance:start -->
Contribution basis: Spark first-party maintenance
Rights holder: Spark Software Development, LLC.
Authorization: REPLACE_WITH_MAINTAINER_AUTHORIZATION_RECORD
Covered submission: REPLACE_WITH_PULL_REQUEST_OR_PATCH_AND_REVISION_SCOPE
Third-party material: REPLACE_WITH_NONE_OR_SOURCE_AND_LICENCE_AND_RESTRICTIONS
<!-- contribution-maintenance:end -->
```

This repository may publish one source snapshot per release. An accepted change can be integrated in private development, then included in a release snapshot. In that case, the pull request is closed with a link to the released version rather than merged directly into the release branch. The closure record identifies the release tag or commit and the included contribution; contributor credit is retained in release notes or an included credits file using the contributor's chosen public name.

The agreement grants limited permissions for contribution forks, review and controlled testing. It does not authorize alternative distributions, public test releases or general hosted services. Rights independently available under applicable law or the hosting platform's terms remain separate. Ask the repository maintainers through a pull request or issue for a written deadline extension or a private contact route for separate licensing; a request alone does not extend permission.

## Spark Contribution Agreement 1.1.0

Copyright 2026, Spark Software Development, LLC.

This agreement is between you and Spark Software Development, LLC (Spark). It applies to contributions to this repository (the upstream repository). It is separate from the unchanged PolyForm Strict License 1.0.0 in [LICENSE.MD](LICENSE.MD), which continues to apply to the software. Spark grants only the additional permissions stated here; this agreement does not relicense third-party material.

### 1. Contributions and ownership

A contribution is code, documentation, data, an asset or another change that you submit for inclusion in the software, whether through a pull request, review suggestion or another expressly identified contribution. Revisions you submit are contributions too. Material clearly identified as not submitted for inclusion is not a contribution.

You keep ownership of your contributions. This agreement does not assign your copyright to Spark. The rights below apply only to rights you own or have authority to grant. Identify the individual or legal entity granting them and your authority to act for it.

### 2. Permission to prepare a contribution

Spark gives you a limited, non-exclusive permission to copy, modify and test the software, and to publish a contribution fork, solely to prepare and submit a particular change to the upstream repository. A contribution fork is any copy made for that purpose, regardless of how it is created or hosted. Individuals and organizations, including employees working on contributions, may use this permission. It does not authorize commercial operation or deployment of the software.

You may run modified copies on your own equipment or controlled test infrastructure to develop and test the change. You may provide temporary test builds, CI artifacts and controlled test sessions, including multiplayer sessions, to identified contributors and reviewers solely to prepare or evaluate that change. Access must be limited to those participants and CI services acting on their behalf, and each participant must have the applicable contribution or review permission. Keep test artifacts in access-controlled storage; public artifact downloads are not permitted under this additional grant. Test access, builds and sessions must end when the applicable permission ends. Public releases, general user access and operation as an alternative product or service remain outside this permission. Permission to use the unmodified software under its base licence remains separate.

A published contribution fork must exist for bona fide contribution work, keep the required notices and these terms, and identify the upstream repository. Do not advertise or promote it as a distribution or a place to obtain the software. Apart from the limited review and testing permissions stated here, this grant gives other people no licence to distribute it or run it for their own purposes. Keep private sources and their test artifacts within the repository's authorized private access unless Spark separately permits public disclosure; this permission does not change repository visibility or access restrictions.

These limits govern the additional contribution permission granted here. They do not restrict rights independently granted under applicable law or the hosting platform's terms. Spark permits the platform uses necessary to host an authorized contribution fork. This does not grant general modification, distribution or service rights beyond those separately available.

### 3. Contribution-fork periods

Permission for a particular change begins when you first make a new copy, or first use an existing copy, to prepare that change. Record that preparation date with the submission. Permission ends at the earliest of:

- 30 days after its pull request is merged or closed;
- 90 days after preparation begins if no pull request has been opened;
- 12 months after its pull request was most recently opened or reopened;
- 24 months after preparation begins; or
- the date you notify Spark that you have abandoned the change.

Opening a pull request within the initial 90 days replaces that initial deadline with the other applicable deadlines. Reopening a pull request restarts the periods measured from opening and resolution, but never the 24-month outer limit. Each separate change has its own periods. Spark may extend a period in writing through the repository maintainers. Maintainers make the applicable preparation date and any extension available to reviewers.

When permission ends, stop developing, publishing and operating the expired change under this agreement, end its test sessions and access, and remove its public copies under your control. Delete the contribution fork or make it private if the hosting platform permits that. A fork may continue solely for another separately authorized active contribution; remove the expired change from active branches and test artifacts. You are not required to remove platform-retained records or copies outside your control. You may keep a private, unpublished copy for records; that does not authorize continued development or operation. Ending this permission does not revoke rights already granted to Spark, require removal of an incorporated contribution, or alter rights independently available under applicable law, the hosting platform's terms or a separate licence.

The base licence's acceptance, patent-defense, violations and no-liability terms also apply to this additional permission. Expiry is a deadline, not an automatic extension through a cure period. Continuing outside the permission is a violation; the base licence's applicable notice and cure provisions still govern that violation.

### 4. Copyright licence to Spark

For each contribution, you grant Spark a worldwide, perpetual, irrevocable, non-exclusive, royalty-free, fully paid-up and transferable copyright licence, with the right to sublicense through multiple tiers, to use, reproduce, modify, prepare derivative works of, display, perform, distribute and otherwise exploit the contribution, alone or with other work, in any medium.

This includes permission to release or relicense your contribution under terms Spark chooses, including commercial and proprietary terms and different terms adopted in future. The grant takes effect when you submit the contribution, whether or not Spark accepts, merges or uses it, and survives closure or withdrawal of a pull request and the end of contribution-fork permission.

### 5. Patent licence and moral rights

You grant Spark and recipients of the software a worldwide, perpetual, irrevocable, non-exclusive, royalty-free, transferable and sublicensable patent licence under claims you own or control, or later have authority to license, that are necessarily infringed by your contribution alone or combined with the software to which you submitted it. It permits making, having made, using, selling, offering for sale, importing and otherwise transferring that software.

To the extent the law permits, you waive and agree not to assert moral rights or similar attribution and integrity rights against the uses licensed here. Where waiver is not permitted, you consent to those uses to the extent you can do so. This does not authorize Spark to claim ownership of rights belonging to someone else.

### 6. Your confirmations and third-party material

You confirm that you are entitled to submit the contribution and grant these rights. If an employer or another person holds relevant rights, you have the necessary permission or authority. You must identify third-party material, its source and its licence, and any terms limiting commercial use, redistribution, modification, sublicensing or the intended licensing model. Those terms must permit the intended inclusion and distribution, and Spark must review compatibility before inclusion. Preserve its notices. Your grants apply to your own rights and do not replace another party's licence.

Except for those confirmations, you provide contributions as is, without additional warranty or condition. You have no obligation to provide support, updates or maintenance. Spark has no obligation to review, accept, use or pay for a contribution.

### 7. Review permission and acceptance

Spark permits reviewers to copy, modify and run the software as changed by a submitted contribution solely to review and test that submission, including the controlled builds, CI artifacts and sessions permitted by section 2. This grants no right to publish releases, provide general user access or operate an alternative product or service. Review permission ends with the applicable contribution permission in section 3; for a submission outside a pull request it ends at the earlier of that time and 30 days after submission. The same 30-day period after a pull request is merged or closed applies to contributors and reviewers, subject to the other section 3 limits. Spark may extend permission in writing. Section 3's cessation, private-record retention and incorporated base-licence provisions also apply to reviewers.

You accept this agreement by exercising its contribution or review permission or intentionally submitting a contribution under it. The versioned acknowledgement required above must come from the actual grantor or its authorized representative and identify the covered submission. Reviewers must read and agree to these terms before exercising review permission. Maintainers record acceptance and revision coverage before integrating an external contribution; they do not infer acceptance from an automated action. That record does not replace the rights and confirmations stated here. Changes to this agreement do not retroactively change the version under which an earlier contribution was made; retain the earlier agreement and grant records. New or revised contributions under a different agreement version require the grantor's acknowledgement of that version for those revisions, without changing prior grants.
