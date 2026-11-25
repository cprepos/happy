# The pod launcher's image, and browser-perms.sh's: the pinned node:22-alpine the launcher ran
# before, plus the acl package (setfacl, getfacl), so the launcher can name the host agent
# (HOST_AGENT_UID) on each fresh slot's downloads, uploads and artifacts, and browser-perms.sh on
# what already exists. Nothing else changes: the same node, no new service, no network at run time.
#
# Built locally (make browser-acl-tools; browser-init and browser-up build it first) and run by
# its local image id, as the Chrome node is. One exact package version from the base image's own
# Alpine release (3.24 at that digest); a new version, or any other change, bumps IMAGE_REVISION.
FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
ARG ACL_VERSION=2.3.2-r1
ARG IMAGE_REVISION=1
RUN apk add --no-cache "acl=${ACL_VERSION}" && setfacl --version && getfacl --version
