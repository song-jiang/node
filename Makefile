##############################################################################
# The build architecture is select by setting the ARCH variable.
# # For example: When building on ppc64le you could use ARCH=ppc64le make <....>.
# # When ARCH is undefined it defaults to amd64.
ARCH?=amd64
ifeq ($(ARCH),amd64)
	ARCHTAG?=
	GO_BUILD_VER?=v0.12
endif

ifeq ($(ARCH),ppc64le)
	ARCHTAG:=-ppc64le
	GO_BUILD_VER?=latest
endif

ifeq ($(ARCH),s390x)
	ARCHTAG:=-s390x
	GO_BUILD_VER?=latest
endif
###############################################################################
CALICO_BUILD?=calico/go-build$(ARCHTAG):$(GO_BUILD_VER)

CALICO_NODE_DIR=$(dir $(realpath $(lastword $(MAKEFILE_LIST))))
###############################################################################

# Version of this repository as reported by git.
CALICO_GIT_VER := $(shell git describe --tags --dirty --always)

# Versions of dependencies used in the build.
CONFD_VER?=master
FELIX_VER?=master 
BIRD_VER?=v0.3.2
GOBGPD_VER?=v0.2.1

# Versions of dependencies used in tests.
CALICOCTL_VER?=master
CNI_VER?=master
RR_VER?=master
SYSTEMTEST_CONTAINER_VER?=latest
ETCD_IMAGE?=quay.io/coreos/etcd:v3.2.5$(ARCHTAG)
HYPERKUBE_IMAGE?=gcr.io/google_containers/hyperkube-$(ARCH):$(K8S_VERSION)

$(info "Build dependency versions")
$(info $(shell printf "%-21s = %-10s\n" "FELIX_VER" $(FELIX_VER)))
$(info $(shell printf "%-21s = %-10s\n" "BIRD_VER" $(BIRD_VER)))
$(info $(shell printf "%-21s = %-10s\n" "CONFD_VER" $(CONFD_VER)))
$(info $(shell printf "%-21s = %-10s\n" "GOBGPD_VER" $(GOBGPD_VER)))

$(info "Test dependency versions")
$(info $(shell printf "%-21s = %-10s\n" "CNI_VER" $(CNI_VER)))
$(info $(shell printf "%-21s = %-10s\n" "RR_VER" $(RR_VER)))

$(info "Calico git version")
$(info $(shell printf "%-21s = %-10s\n" "CALICO_GIT_VER" $(CALICO_GIT_VER)))

# We can use "custom" build image and test image name
SYSTEMTEST_CONTAINER?=calico/test$(ARCHTAG):$(SYSTEMTEST_CONTAINER_VER)

# Ensure that the dist directory is always created
MAKE_SURE_BIN_EXIST := $(shell mkdir -p dist)

###############################################################################
# URL for Calico binaries
# bird binaries
BIRD_URL?=https://github.com/projectcalico/calico-bird/releases/download/$(BIRD_VER)/bird
BIRD6_URL?=https://github.com/projectcalico/calico-bird/releases/download/$(BIRD_VER)/bird6
BIRDCL_URL?=https://github.com/projectcalico/calico-bird/releases/download/$(BIRD_VER)/birdcl
CALICO_BGP_DAEMON_URL?=https://github.com/projectcalico/calico-bgp-daemon/releases/download/$(GOBGPD_VER)/calico-bgp-daemon

###############################################################################
# calico/node build. Contains the following areas
# - Populate the calico_node/filesystem
# - Build the container itself
###############################################################################
NODE_CONTAINER_NAME?=calico/node$(ARCHTAG)
NODE_CONTAINER_CREATED=.calico_node.created
NODE_CONTAINER_BIN_DIR=./filesystem/bin
NODE_CONTAINER_BINARIES=startup readiness allocate-ipip-addr calico-felix bird calico-bgp-daemon confd

FELIX_REPO?=calico/felix
FELIX_CONTAINER_NAME?=$(FELIX_REPO)$(ARCHTAG):$(FELIX_VER)
CONFD_REPO?=calico/confd
CONFD_CONTAINER_NAME?=$(CONFD_REPO)$(ARCHTAG):$(CONFD_VER)

NODE_CONTAINER_FILES=$(shell find ./filesystem -type f)
STARTUP_FILES=$(shell find ./pkg/startup -name '*.go')
ALLOCATE_IPIP_FILES=$(shell find ./pkg/allocateipip -name '*.go')
READINESS_FILES=$(shell find ./pkg/readiness -name '*.go')

TEST_CONTAINER_NAME?=calico/test$(ARCHTAG):latest
TEST_CONTAINER_FILES=$(shell find tests/ -type f ! -name '*.created')

LOCAL_USER_ID?=$(shell id -u $$USER)

LDFLAGS=-ldflags "-X main.VERSION=$(CALICO_GIT_VER)"

PACKAGE_NAME?=github.com/projectcalico/node

LIBCALICOGO_PATH?=none

# Whether the update-felix target should pull the felix image.
PULL_FELIX?=true

# Use this to populate the vendor directory after checking out the repository.
# To update upstream dependencies, delete the glide.lock file first.
vendor: glide.yaml
	# Ensure that the glide cache directory exists.
	mkdir -p $(HOME)/.glide

	# To build without Docker just run "glide install -strip-vendor"
	if [ "$(LIBCALICOGO_PATH)" != "none" ]; then \
          EXTRA_DOCKER_BIND="-v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro"; \
	fi; \

	docker run --rm \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw $$EXTRA_DOCKER_BIND \
		-v $(HOME)/.glide:/home/user/.glide:rw \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		$(CALICO_BUILD) \
		/bin/sh -c 'cd /go/src/$(PACKAGE_NAME) && glide install -strip-vendor'

## Create the calico/node image.
calico/node: $(NODE_CONTAINER_NAME)
$(NODE_CONTAINER_NAME): $(NODE_CONTAINER_CREATED)
$(NODE_CONTAINER_CREATED): ./Dockerfile$(ARCHTAG) $(NODE_CONTAINER_FILES) $(addprefix $(NODE_CONTAINER_BIN_DIR)/,$(NODE_CONTAINER_BINARIES))
	# Check versions of the binaries that we're going to use to build calico/node.
	# startup: doesn't support --version or -v
	# allocate-ipip-addr: doesn't support --version or -v
	# Since the binaries are built for Linux, run them in a container to allow the
	# make target to be run on different platforms (e.g. MacOS).
	docker run --rm -v $(CURDIR)/$(NODE_CONTAINER_BIN_DIR):/go/bin:rw $(CALICO_BUILD) /bin/sh -c "\
	  echo; echo calico-felix --version; /go/bin/calico-felix --version; \
	  echo; echo bird --version;         /go/bin/bird --version; \
	  echo; echo calico-bgp-daemon -v;   /go/bin/calico-bgp-daemon -v; \
	  echo; echo confd --version;        /go/bin/confd --version; \
	"
	docker build --pull -t $(NODE_CONTAINER_NAME) . -f ./Dockerfile$(ARCHTAG)
	touch $@

# Get felix binaries
.PHONY: update-felix
$(NODE_CONTAINER_BIN_DIR)/calico-felix update-felix:
	-docker rm -f calico-felix
	# Latest felix binaries are stored in automated builds of calico/felix.
	# To get them, we create (but don't start) a container from that image.
	if $(PULL_FELIX); then docker pull $(FELIX_CONTAINER_NAME); fi
	docker create --name calico-felix $(FELIX_CONTAINER_NAME)
	# Then we copy the files out of the container.  Since docker preserves
	# mtimes on its copy, check the file really did appear, then touch it
	# to make sure that downstream targets get rebuilt.
	docker cp calico-felix:/code/. $(NODE_CONTAINER_BIN_DIR) && \
	  test -e $(NODE_CONTAINER_BIN_DIR)/calico-felix && \
	  touch $(NODE_CONTAINER_BIN_DIR)/calico-felix
	-docker rm -f calico-felix

# Get the confd binary
$(NODE_CONTAINER_BIN_DIR)/confd:
	-docker rm -f calico-confd
	# Latest confd binaries are stored in automated builds of calico/confd.
	# To get them, we create (but don't start) a container from that image.
	docker pull $(CONFD_CONTAINER_NAME)
	docker create --name calico-confd $(CONFD_CONTAINER_NAME)
	# Then we copy the files out of the container.  Since docker preserves
	# mtimes on its copy, check the file really did appear, then touch it
	# to make sure that downstream targets get rebuilt.
	docker cp calico-confd:/bin/confd $(NODE_CONTAINER_BIN_DIR) && \
	  test -e $(NODE_CONTAINER_BIN_DIR)/confd && \
	  touch $(NODE_CONTAINER_BIN_DIR)/confd
	-docker rm -f calico-confd
	chmod +x $@

# Get the calico-bgp-daemon binary
$(NODE_CONTAINER_BIN_DIR)/calico-bgp-daemon:
	$(CURL) -L $(CALICO_BGP_DAEMON_URL) -o $@
	chmod +x $(@D)/*

# Get bird binaries
$(NODE_CONTAINER_BIN_DIR)/bird:
	# This make target actually downloads the bird6 and birdcl binaries too
	# Copy patched BIRD daemon with tunnel support.
	$(CURL) -L $(BIRD6_URL) -o $(@D)/bird6
	$(CURL) -L $(BIRDCL_URL) -o $(@D)/birdcl
	$(CURL) -L $(BIRD_URL) -o $@
	chmod +x $(@D)/*

$(NODE_CONTAINER_BIN_DIR)/startup: dist/startup
	mkdir -p $(NODE_CONTAINER_BIN_DIR)
	cp dist/startup $(NODE_CONTAINER_BIN_DIR)/startup

$(NODE_CONTAINER_BIN_DIR)/readiness: dist/readiness
	mkdir -p $(NODE_CONTAINER_BIN_DIR)
	cp dist/readiness $(NODE_CONTAINER_BIN_DIR)/readiness

$(NODE_CONTAINER_BIN_DIR)/allocate-ipip-addr: dist/allocate-ipip-addr
	mkdir -p $(NODE_CONTAINER_BIN_DIR)
	cp dist/allocate-ipip-addr $(NODE_CONTAINER_BIN_DIR)/allocate-ipip-addr

# Build startup.go
dist/startup: $(STARTUP_FILES) vendor
	mkdir -p dist
	mkdir -p .go-pkg-cache
	docker run --rm \
		-e ARCH=$(ARCH) \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
		-v $(CURDIR)/dist:/go/src/$(PACKAGE_NAME)/dist \
	  	$(CALICO_BUILD) sh -c '\
			cd /go/src/$(PACKAGE_NAME) && \
			make CALICO_GIT_VER=$(CALICO_GIT_VER) startup'

# Build readiness.go
dist/readiness: $(HEALTHCHECK_FILES) vendor
	mkdir -p dist
	mkdir -p .go-pkg-cache
	docker run --rm \
		-e ARCH=$(ARCH) \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
		-v $(CURDIR)/dist:/go/src/$(PACKAGE_NAME)/dist \
	  	$(CALICO_BUILD) sh -c '\
			cd /go/src/$(PACKAGE_NAME) && \
			make CALICO_GIT_VER=$(CALICO_GIT_VER) readiness'

# Build allocate_ipip_addr.go
dist/allocate-ipip-addr: $(ALLOCATE_IPIP_FILES) vendor
	mkdir -p dist
	mkdir -p .go-pkg-cache
	docker run --rm \
	-e ARCH=$(ARCH) \
	-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
	-v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
	-v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
	-v $(CURDIR)/dist:/go/src/$(PACKAGE_NAME)/dist \
	  $(CALICO_BUILD) sh -c '\
		cd /go/src/$(PACKAGE_NAME) && \
		make CALICO_GIT_VER=$(CALICO_GIT_VER) allocate-ipip-addr'

.PHONY: startup
startup:
	GOOS=linux GOARCH=$(ARCH) CGO_ENABLED=0 go build -v -i -o dist/startup $(LDFLAGS) pkg/startup/startup.go

.PHONY: readiness
readiness:
	GOOS=linux GOARCH=$(ARCH) CGO_ENABLED=0 go build -v -i -o dist/readiness $(LDFLAGS) pkg/readiness/readiness.go

.PHONY: allocate-ipip-addr
allocate-ipip-addr:
	GOOS=linux GOARCH=$(ARCH) CGO_ENABLED=0 go build -v -i -o dist/allocate-ipip-addr $(LDFLAGS) pkg/allocateipip/allocate_ipip_addr.go

###############################################################################
# Tests
# - Support for running etcd (both securely and insecurely)
# - Running UTs and STs
###############################################################################
# These variables can be overridden by setting an environment variable.
###############################################################################
# Common build variables
# Path to the sources.
# Default value: directory with Makefile
SOURCE_DIR?=$(dir $(lastword $(MAKEFILE_LIST)))
SOURCE_DIR:=$(abspath $(SOURCE_DIR))
CRD_PATH=$(CURDIR)/vendor/github.com/projectcalico/libcalico-go/test/
LOCAL_IP_ENV?=$(shell ip route get 8.8.8.8 | head -1 | awk '{print $$7}')
K8S_VERSION=v1.7.4
ST_TO_RUN?=tests/st/

CTL_CONTAINER_NAME?=calico/ctl$(ARCHTAG):$(CALICOCTL_VER)
RR_CONTAINER_NAME?=calico/routereflector$(ARCHTAG)

# Can exclude the slower tests with "-a '!slow'"
ST_OPTIONS?=
HOST_CHECKOUT_DIR?=$(shell pwd)

# curl should failed on 404
CURL=curl -sSf

certs/cfssl certs/cfssljson:
	mkdir -p certs
	$(CURL) -L "https://github.com/projectcalico/cfssl/releases/download/1.2.1/cfssl" -o certs/cfssl
	$(CURL) -L "https://github.com/projectcalico/cfssl/releases/download/1.2.1/cfssljson" -o certs/cfssljson
	chmod a+x certs/cfssl
	chmod a+x certs/cfssljson

## Generate the keys and certificates for running etcd with SSL.
ssl-certs: certs/.certificates.created
certs/.certificates.created: certs/cfssl certs/cfssljson
	certs/cfssl gencert -initca tests/st/ssl-config/ca-csr.json | certs/cfssljson -bare certs/ca
	certs/cfssl gencert \
	  -ca certs/ca.pem \
	  -ca-key certs/ca-key.pem \
	  -config tests/st/ssl-config/ca-config.json \
	  tests/st/ssl-config/req-csr.json | certs/cfssljson -bare certs/client
	certs/cfssl gencert \
	  -ca certs/ca.pem \
	  -ca-key certs/ca-key.pem \
	  -config tests/st/ssl-config/ca-config.json \
	  tests/st/ssl-config/req-csr.json | certs/cfssljson -bare certs/server

	touch certs/.certificates.created

busybox.tar:
	docker pull $(ARCH)/busybox:latest
	docker save --output busybox.tar $(ARCH)/busybox:latest

routereflector.tar:
	-docker pull calico/routereflector$(ARCHTAG):$(RR_VER)
	docker save --output routereflector.tar calico/routereflector$(ARCHTAG):$(RR_VER)

workload.tar:
	cd workload && docker build -t workload -f Dockerfile$(ARCHTAG) .
	docker save --output workload.tar workload

stop-etcd:
	@-docker rm -f calico-etcd calico-etcd-ssl

.PHONY: run-etcd-ssl
# Run etcd in a container with SSL verification. Used primarily by STs.
run-etcd-ssl: certs/.certificates.created add-ssl-hostname
	$(MAKE) stop-etcd
	docker run --detach \
	--net=host \
	-v $(SOURCE_DIR)/certs:/etc/calico/certs \
	--name calico-etcd-ssl $(ETCD_IMAGE) \
	etcd \
	--cert-file "/etc/calico/certs/server.pem" \
	--key-file "/etc/calico/certs/server-key.pem" \
	--trusted-ca-file "/etc/calico/certs/ca.pem" \
	--advertise-client-urls "https://etcd-authority-ssl:2379,https://localhost:2379" \
	--listen-client-urls "https://0.0.0.0:2379"

IPT_ALLOW_ETCD:=-A INPUT -i docker0 -p tcp --dport 2379 -m comment --comment "calico-st-allow-etcd" -j ACCEPT

# Download calicoctl v1.0.2 from releases.  Used for STs (testing pre/post v1.1.0 data model)
dist/calicoctl-v1.0.2:
	wget https://github.com/projectcalico/calicoctl/releases/download/v1.0.2/calicoctl -O dist/calicoctl-v1.0.2
	chmod +x dist/calicoctl-v1.0.2

# Pull calicoctl and CNI plugin binaries with versions as per XXX_VER
# variables.  These are used for the STs.
dist/calicoctl:
	-docker rm -f calicoctl
	docker pull $(CTL_CONTAINER_NAME)
	docker create --name calicoctl $(CTL_CONTAINER_NAME)
	docker cp calicoctl:calicoctl dist/calicoctl && \
	  test -e dist/calicoctl && \
	  touch dist/calicoctl
	-docker rm -f calicoctl
dist/calico-cni-plugin dist/calico-ipam-plugin:
	-docker rm -f calico-cni
	docker pull calico/cni:$(CNI_VER)
	docker create --name calico-cni calico/cni:$(CNI_VER)
	docker cp calico-cni:/opt/cni/bin/calico dist/calico-cni-plugin && \
	  test -e dist/calico-cni-plugin && \
	  touch dist/calico-cni-plugin
	docker cp calico-cni:/opt/cni/bin/calico-ipam dist/calico-ipam-plugin && \
	  test -e dist/calico-ipam-plugin && \
	  touch dist/calico-ipam-plugin
	-docker rm -f calico-cni

# Create the calico/test image
test_image: calico_test.created 
calico_test.created: $(TEST_CONTAINER_FILES)
	cd calico_test && docker build -f Dockerfile$(ARCHTAG).calico_test -t $(TEST_CONTAINER_NAME) .
	touch calico_test.created

calico-node.tar: $(NODE_CONTAINER_CREATED)
	# Check versions of the Calico binaries that will be in calico-node.tar.
	# Since the binaries are built for Linux, run them in a container to allow the
	# make target to be run on different platforms (e.g. MacOS).
	docker run --rm $(NODE_CONTAINER_NAME) /bin/sh -c "\
	  echo calico-felix --version; /bin/calico-felix --version; \
	  echo bird --version;         /bin/bird --version; \
	  echo calico-bgp-daemon -v;   /bin/calico-bgp-daemon -v; \
	  echo confd --version;        /bin/confd --version; \
	"
	docker save --output $@ $(NODE_CONTAINER_NAME)

# Build ACI (the APPC image file format) of calico/node.
# Requires docker2aci installed on host: https://github.com/appc/docker2aci
calico-node-latest.aci: calico-node.tar
	docker2aci $<

.PHONY: st-checks
st-checks:
	# Check that we're running as root.
	test `id -u` -eq '0' || { echo "STs must be run as root to allow writes to /proc"; false; }

	# Insert an iptables rule to allow access from our test containers to etcd
	# running on the host.
	iptables-save | grep -q 'calico-st-allow-etcd' || iptables $(IPT_ALLOW_ETCD)

.PHONY: st
## Run the system tests 
st: dist/calicoctl dist/calicoctl-v1.0.2 busybox.tar routereflector.tar calico-node.tar workload.tar run-etcd calico_test.created dist/calico-cni-plugin dist/calico-ipam-plugin
	# Check versions of Calico binaries that ST execution will use.
	docker run --rm -v $(CURDIR)/dist:/go/bin:rw $(CALICO_BUILD) /bin/sh -c "\
	  echo; echo calicoctl --version;        /go/bin/calicoctl --version; \
	  echo; echo calicoctl-v1.0.2 --version; /go/bin/calicoctl-v1.0.2 --version; \
	  echo; echo calico-cni-plugin -v;       /go/bin/calico-cni-plugin -v; \
	  echo; echo calico-ipam-plugin -v;      /go/bin/calico-ipam-plugin -v; echo; \
	"
	# Use the host, PID and network namespaces from the host.
	# Privileged is needed since 'calico node' write to /proc (to enable ip_forwarding)
	# Map the docker socket in so docker can be used from inside the container
	# HOST_CHECKOUT_DIR is used for volume mounts on containers started by this one.
	# All of code under test is mounted into the container.
	#   - This also provides access to calicoctl and the docker client
	# $(MAKE) st-checks
	docker run --uts=host \
	           --pid=host \
	           --net=host \
	           --privileged \
	           -e HOST_CHECKOUT_DIR=$(HOST_CHECKOUT_DIR) \
	           -e DEBUG_FAILURES=$(DEBUG_FAILURES) \
	           -e MY_IP=$(LOCAL_IP_ENV) \
	           -e NODE_CONTAINER_NAME=$(NODE_CONTAINER_NAME) \
		   -e RR_CONTAINER_NAME=$(RR_CONTAINER_NAME):$(RR_VER) \
	           --rm -t \
	           -v /var/run/docker.sock:/var/run/docker.sock \
	           -v $(SOURCE_DIR):/code \
	           $(SYSTEMTEST_CONTAINER) \
	           sh -c 'nosetests $(ST_TO_RUN) -sv --nologcapture  --with-xunit --xunit-file="/code/nosetests.xml" --with-timer $(ST_OPTIONS)'
	$(MAKE) stop-etcd

# Run the STs in a container using etcd with SSL certificate/key/CA verification.
.PHONY: st-ssl
st-ssl: run-etcd-ssl dist/calicoctl busybox.tar calico-node.tar routereflector.tar workload.tar calico_test.created
	# Use the host, PID and network namespaces from the host.
	# Privileged is needed since 'calico node' write to /proc (to enable ip_forwarding)
	# Map the docker socket in so docker can be used from inside the container
	# HOST_CHECKOUT_DIR is used for volume mounts on containers started by this one.
	# All of code under test is mounted into the container.
	#   - This also provides access to calicoctl and the docker client
	# Mount the full path to the etcd certs directory.
	#   - docker copies this directory directly from the host, but the
	#     calicoctl node command reads the files from the test container
	$(MAKE) st-checks
	docker run --uts=host \
	           --pid=host \
	           --net=host \
	           --privileged \
	           -e HOST_CHECKOUT_DIR=$(HOST_CHECKOUT_DIR) \
	           -e DEBUG_FAILURES=$(DEBUG_FAILURES) \
	           -e MY_IP=$(LOCAL_IP_ENV) \
	           -e NODE_CONTAINER_NAME=$(NODE_CONTAINER_NAME) \
		   -e RR_CONTAINER_NAME=$(RR_CONTAINER_NAME):$(RR_VER) \
	           -e ETCD_SCHEME=https \
	           -e ETCD_CA_CERT_FILE=$(SOURCE_DIR)/certs/ca.pem \
	           -e ETCD_CERT_FILE=$(SOURCE_DIR)/certs/client.pem \
	           -e ETCD_KEY_FILE=$(SOURCE_DIR)/certs/client-key.pem \
	           --rm -t \
	           -v /var/run/docker.sock:/var/run/docker.sock \
	           -v $(SOURCE_DIR):/code \
	           -v $(SOURCE_DIR)/certs:$(SOURCE_DIR)/certs \
	           $(SYSTEMTEST_CONTAINER) \
	           sh -c 'nosetests $(ST_TO_RUN) -sv --nologcapture --with-xunit --xunit-file="/code/nosetests.xml" --with-timer $(ST_OPTIONS)'
	$(MAKE) stop-etcd

.PHONY: add-ssl-hostname
add-ssl-hostname:
	# Set "LOCAL_IP etcd-authority-ssl" in /etc/hosts to use as a hostname for etcd with ssl
	if ! grep -q "etcd-authority-ssl" /etc/hosts; then \
	  echo "\n# Host used by Calico's ETCD with SSL\n$(LOCAL_IP_ENV) etcd-authority-ssl" >> /etc/hosts; \
	fi

###############################################################################
# Test targets 
###############################################################################
.PHONY: fv
# Run the Functional Verification tests locally, must have local etcd running
run-fvs: 
	# Run tests in random order find tests recursively (-r).
	ginkgo -cover -r -skipPackage vendor pkg/startup pkg/allocateipip pkg/calicoclient

	@echo
	@echo '+==============+'
	@echo '| All coverage |'
	@echo '+==============+'
	@echo
	@find . -iname '*.coverprofile' | xargs -I _ go tool cover -func=_

	@echo
	@echo '+==================+'
	@echo '| Missing coverage |'
	@echo '+==================+'
	@echo
	@find . -iname '*.coverprofile' | xargs -I _ go tool cover -func=_ | grep -v '100.0%'

PHONY: fv
## Run the ginkgo FVs 
fv: vendor run-etcd run-k8s-apiserver
	docker run --rm \
	-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
	-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
	-e ETCD_ENDPOINTS=http://$(LOCAL_IP_ENV):2379 \
	--net=host \
	$(CALICO_BUILD) sh -c 'cd /go/src/$(PACKAGE_NAME) && make run-fvs'

	# Tear down k8s apiserver afterwards.
	$(MAKE) stop-k8s-apiserver stop-etcd

.PHONY: ci
ci:
	# Run the containerized FV tests first.
	$(MAKE) fv

	# Build images and run the system tests.
	$(MAKE) $(NODE_CONTAINER_NAME) st

	# Run a small subset of the tests for testing SSL support.
	ST_TO_RUN=tests/st/policy $(MAKE) st-ssl

# This depends on clean to ensure that dependent images get untagged and repulled
# THIS JOB DELETES LOTS OF THINGS - DO NOT RUN IT ON YOUR LOCAL DEV MACHINE.
.PHONY: semaphore
semaphore:
	# Clean up unwanted files to free disk space.
	bash -c 'rm -rf /usr/local/golang /opt /var/lib/mongodb /usr/lib/jvm /home/runner/{.npm,.phpbrew,.phpunit,.kerl,.kiex,.lein,.nvm,.npm,.phpbrew,.rbenv}'
	$(MAKE) ci

# etcd is used by the STs
.PHONY: run-etcd
run-etcd:
	@-docker rm -f calico-etcd
	docker run --detach \
	--net=host \
	--name calico-etcd $(ETCD_IMAGE) \
	etcd \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379" \
	--listen-client-urls "http://0.0.0.0:2379"

# Kubernetes apiserver used for tests
run-k8s-apiserver: stop-k8s-apiserver run-etcd vendor
	docker run \
		--net=host --name st-apiserver \
		--detach \
		${HYPERKUBE_IMAGE} \
		/hyperkube apiserver \
			--bind-address=0.0.0.0 \
			--insecure-bind-address=0.0.0.0 \
				--etcd-servers=http://127.0.0.1:2379 \
			--admission-control=NamespaceLifecycle,LimitRanger,DefaultStorageClass,ResourceQuota \
			--authorization-mode=RBAC \
			--service-cluster-ip-range=10.101.0.0/16 \
			--v=10 \
			--logtostderr=true

	# Wait until we can configure a cluster role binding which allows anonymous auth.
	while ! docker exec st-apiserver kubectl create \
		clusterrolebinding anonymous-admin \
		--clusterrole=cluster-admin \
		--user=system:anonymous; \
		do echo "Trying to create ClusterRoleBinding"; \
		sleep 2; \
		done

	# Create CustomResourceDefinition (CRD) for Calico resources
	# from the manifest crds.yaml
	docker run \
		--net=host \
		--rm \
		-v  $(CRD_PATH):/manifests \
		lachlanevenson/k8s-kubectl$(ARCHTAG):$(K8S_VERSION) \
		--server=http://localhost:8080 \
		apply -f /manifests/crds.yaml

# Stop Kubernetes apiserver
stop-k8s-apiserver:
	@-docker rm -f st-apiserver

###############################################################################
# Release targets 
###############################################################################
release: clean release-prereqs 
	git tag $(VERSION)

	# Build the calico/node images.
	$(MAKE) $(NODE_CONTAINER_NAME)

	# Retag images with corect version and quay
	docker tag $(NODE_CONTAINER_NAME) $(NODE_CONTAINER_NAME):$(VERSION)
	docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):$(VERSION)
	docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):latest

	# Create the release archive
	$(MAKE) release-archive

	# Check that images were created recently and that the IDs of the versioned and latest images match
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(NODE_CONTAINER_NAME)
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(NODE_CONTAINER_NAME):$(VERSION)

	# Check that the images container the right sub-components
	docker run $(NODE_CONTAINER_NAME) calico-felix --version

	@echo "# See RELEASING.md for detailed instructions."
	@echo "# Now push release images."
	@echo "  docker push $(NODE_CONTAINER_NAME):$(VERSION)"
	@echo "  docker push quay.io/$(NODE_CONTAINER_NAME):$(VERSION)"

	@echo "# For the final release only, push the latest tag (not for RCs)"
	@echo "  docker push $(NODE_CONTAINER_NAME):latest"
	@echo "  docker push quay.io/$(NODE_CONTAINER_NAME):latest"

	@echo "# Only push the git tag AFTER this branch is merged to origin/master"
	@echo "  git push origin $(VERSION)"

.PHONY: node-test-at
# Run calico/node docker-image acceptance tests
node-test-at: release-prereq
	docker run -v $(CALICO_NODE_DIR)tests/at/calico_node_goss.yaml:/tmp/goss.yaml \
        -e CALICO_BGP_DAEMON_VER=$(GOBGPD_VER) \
        -e CALICO_FELIX_VER=$(FELIX_VER) \
        -e CONFD_VER=$(CONFD_VER) \
	calico/node:$(VERSION) /bin/sh -c 'apk --no-cache add wget ca-certificates && \
	wget -q -O /tmp/goss \
	https://github.com/aelsabbahy/goss/releases/download/v0.3.4/goss-linux-amd64 && \
	chmod +rx /tmp/goss && \
	/tmp/goss --gossfile /tmp/goss.yaml validate'

# release-prereqs checks that the environment is configured properly to create a release.
release-prereqs:
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif

###############################################################################
# Utilities 
###############################################################################

## Clean enough that a new release build will be clean
clean:
	find . -name '*.created' -exec rm -f {} +
	find . -name '*.pyc' -exec rm -f {} +
	rm -rf dist build certs *.tar vendor ./filesystem/bin

	# Delete images that we built in this repo
	docker rmi $(NODE_CONTAINER_NAME):latest || true
	docker rmi $(SYSTEMTEST_CONTAINER) || true

	# Retag and remove external images so that they will be pulled again
	# We avoid just deleting the image. We didn't build them here so it would be impolite to delete it.
	docker tag $(FELIX_CONTAINER_NAME) $(FELIX_CONTAINER_NAME)-backup && docker rmi $(FELIX_CONTAINER_NAME) || true

.PHONY: help
## Display this help text
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	$(info Available targets)
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {                                      \
		nb = sub( /^## /, "", helpMsg );                                \
		if(nb == 0) {                                                   \
			helpMsg = $$0;                                              \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );                   \
		}                                                               \
		if (nb)                                                         \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}                                                                   \
	{ helpMsg = $$0 }'                                                  \
	width=20                                                            \
	$(MAKEFILE_LIST)
