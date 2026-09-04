# frozen_string_literal: true

# Development environment for firefox-wasm: Gecko (the Firefox engine)
# compiled to WebAssembly. Ubuntu 24.04 LTS + emsdk 6.0.1.
#
#   rake dev:up   # boots the VM, builds the engine on first run (~45 min),
#                 # then serves the demo at http://localhost:8080
#
# Edit on the host, compile in the VM: the repo working tree is synced
# host -> VM (rsync) on `vagrant up`/`reload` and by `rake dev:compile`.
#
# Works with both libvirt (default on Linux) and VirtualBox:
#
#   vagrant up                # uses libvirt
#   vagrant up --provider=virtualbox
#
# VM resources can be tuned via environment variables, e.g.:
#
#   FW_CPUS=12 FW_MEMORY=24576 vagrant up
#
# Note: compiling Gecko with Emscripten is RAM-hungry (non-LTO links peak at
# several GB); 8 CPUs / 16 GB matches the project's proven CI runner size.

VAGRANTFILE_API_VERSION = "2"

VM_CPUS   = (ENV["FW_CPUS"]   || 8).to_i
VM_MEMORY = (ENV["FW_MEMORY"] || 16384).to_i

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "cloud-image/ubuntu-24.04"

  config.vm.hostname = "firefox-wasm"

  # Serve the built web app from the VM (e.g. the vite demo server).
  config.vm.network "forwarded_port", guest: 8000, host: 8000, host_ip: "127.0.0.1"

  config.vm.synced_folder ".", "/vagrant", disabled: true

  # The whole repo -> ~/firefox-wasm in the VM. The heavy/regenerable dirs
  # stay VM-local (excluded, which also protects them from --delete):
  #   firefox/    5.8G engine checkout, fetched by the Makefile
  #   emsdk/      repo-local emsdk 6.0.1, installed by `make emsdk`
  #   obj-*/      build objdirs
  config.vm.synced_folder ".", "/home/vagrant/firefox-wasm",
                          type: "rsync",
                          rsync__args: ["--verbose", "--archive", "--delete", "-z", "--copy-links"],
                          rsync__exclude: [
                            ".git/",
                            ".vagrant/",
                            "firefox/",
                            "emsdk/",
                            "obj-full-emscripten*/",
                            "**/node_modules/",
                            "gecko.js/build/",
                            "gecko.js/wasm/",
                            "gecko.js/dist/",
                            "demo/*/dist/",
                            "build.log",
                            "demo.log"
                          ]

  config.vm.provider :libvirt do |libvirt|
    libvirt.cpus   = VM_CPUS
    libvirt.memory = VM_MEMORY
  end

  config.vm.provider :virtualbox do |vb|
    vb.cpus   = VM_CPUS
    vb.memory = VM_MEMORY
  end

  config.vm.provision "shell", path: "provision.sh", privileged: false
end
