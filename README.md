# tp_basic

Playbooks and roles for [telepatch](https://github.com/resurgentech/telepatch):
the basic development workstation, build container and server configurations
that the [ansible](https://github.com/resurgentech/ansible) repo used to hold.

telepatch is the engine. This repo is what runs on it, the way a playbook
repo relates to Ansible itself.

**Status:** being ported. The Ansible originals are pulled into
`conversion/` as they are worked on, each with a short document of what the
playbook and its roles are for, whether the methods they use are still the
right ones, and the decisions made. A role leaves `conversion/` when its
telepatch version exists; the understanding goes into the code as comments.
