# Third-party license inventory

`modules.tsv` is the reviewed inventory for every module declared by
`notifier/go.mod`. The `licenses/` tree preserves the upstream license and NOTICE
files at their package paths so they can be copied without rewriting legal text.

The initial inventory was generated with `google/go-licenses` v1.6.0 against
`./plugin` and `./mailer/cmd/threadhub-mailer`, then reconciled with `go.mod`.
`modernc.org/mathutil` v1.7.1 omits a recognizable license file from its Go module
archive, so its BSD-3-Clause text was copied from the upstream cznic/mathutil
repository and checked against the Go package license metadata.

Do not regenerate this directory without review. A successful scanner exit does
not replace verification of the module version, upstream license, NOTICE files,
MPL source availability, or the artifact contents.
