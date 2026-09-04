# frozen_string_literal: true

# Development tasks for firefox-wasm: Gecko (the Firefox engine)
# compiled to WebAssembly. Edit on the host, compile in the Vagrant VM.
#
#   rake dev:up
#
# ...then open http://localhost:8080 in your browser.
#
# The first run builds the whole Gecko engine (~45 min, one time only;
# subsequent runs reuse the build inside the VM).

VM_REPO    = "~/firefox-wasm"  # rsync target of this repo's working tree
GUEST_PORT = 8000  # vite dev server inside the VM
HOST_PORT  = 8080  # ssh tunnel on the host (localhost = secure context for COOP/COEP)
TUNNEL_LOG = "/tmp/browser-in-browser-tunnel.log"
MIN_DISK_GB = 150  # the Gecko checkout + emsdk + objdir need ~60 GB; box ships 10 GB

def ssh(cmd, quiet: false)
  opts = quiet ? { %i[out err] => File::NULL } : {}
  system("vagrant", "ssh", "-c", cmd, **opts)
end

def ssh!(cmd)
  ssh(cmd) || abort("!! failed: vagrant ssh -c '#{cmd}'")
end

# Incremental engine build: mach rebuilds only what changed (no clean).
# PATH order matters: $PWD/emsdk contains a *directory* named `node`, and GNU
# make's fast-path exec of bare recipe lines (`node ...`) stops at it with
# EACCES instead of continuing the search -- so the real node must come first.
BUILD_CMD = 'cd ~/firefox-wasm && ulimit -s unlimited && ' \
            'export PATH="$PWD/emsdk/upstream/emscripten:$PATH:$PWD/emsdk" ' \
            'LIBCLANG_PATH=/usr/lib/llvm-21/lib && make web'

def engine_built?
  ssh("test -f #{VM_REPO}/gecko.js/dist/gecko.wasm", quiet: true)
end

# Push host edits (this repo's working tree) into the VM.
def sync_sources
  abort("!! Makefile not found -- run rake from the firefox-wasm repo root") \
    unless File.exist?("Makefile")
  system("vagrant", "rsync", %i[out err] => File::NULL) \
    || abort("!! vagrant rsync failed -- is the VM up? (rake dev:up)")
end

def build_engine
  puts "==> Syncing sources and building the Gecko engine to wasm (first run only, ~45 min)..."
  sync_sources
  ssh!(BUILD_CMD)
end

def start_demo_server
  # Restart vite detached; ssh may stay attached to the spawned process,
  # so cap it with timeout -- the server (new session) survives.
  # fuser kills by port: pkill -f vite would match the launching shell itself.
  remote = "fuser -k #{GUEST_PORT}/tcp 2>/dev/null; sleep 2; " \
           "cd #{VM_REPO}/demo/embed && " \
           "setsid nohup pnpm exec vite --host 0.0.0.0 --port #{GUEST_PORT} --strictPort " \
           "> demo.log 2>&1 < /dev/null &"
  system("timeout", "30", "vagrant", "ssh", "-c", remote, %i[out err] => File::NULL)
end

def demo_serving?
  ssh("curl -sf -o /dev/null http://127.0.0.1:#{GUEST_PORT}/", quiet: true)
end

def wait_for_demo(tries: 30)
  tries.times do
    return true if demo_serving?
    sleep 1
  end
  false
end

def tunnel_running?
  system("pgrep", "-f", "#{HOST_PORT}:localhost:#{GUEST_PORT}", %i[out err] => File::NULL)
end

def start_tunnel
  pid = spawn("vagrant", "ssh", "--", "-N",
              "-L", "127.0.0.1:#{HOST_PORT}:localhost:#{GUEST_PORT}",
              "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes",
              in: :close, out: TUNNEL_LOG, err: TUNNEL_LOG, pgroup: true)
  Process.detach(pid)
end

def wait_for_http(url, tries: 30)
  tries.times do
    return true if system("curl", "-sf", "-o", File::NULL, url, %i[out err] => File::NULL)
    sleep 1
  end
  false
end

# vagrant-libvirt creates the root disk at the box's virtual size (10 GB) --
# far too small for the Gecko build. Grow it online (sparse qcow2: no upfront
# host disk cost), then grow the guest partition + filesystem. Idempotent.
def ensure_disk_size
  id_file = ".vagrant/machines/default/libvirt/id"
  return unless File.exist?(id_file) && system("which", "virsh", %i[out err] => File::NULL)

  id = File.read(id_file).strip
  info = `virsh -c qemu:///system domblkinfo #{id} vda 2>/dev/null`
  capacity = info[/^Capacity:\s+(\d+)/, 1].to_i
  if capacity < MIN_DISK_GB * 1024**3
    puts "==> Growing VM disk to #{MIN_DISK_GB} GB (one time)"
    system("virsh", "-c", "qemu:///system", "blockresize", id, "vda", "#{MIN_DISK_GB}G") \
      || abort("!! virsh blockresize failed")
    ssh("sudo growpart /dev/vda 1 || true; sudo resize2fs /dev/vda1") \
      || abort("!! growpart/resize2fs failed")
  end

  # 24G swap for the libxul/wasm-opt link peaks. provision.sh skips it while
  # the disk is still the small box image, so (re)create it once there's room.
  swap_cmd = "swapon --show | grep -q swapfile || { " \
             "sudo fallocate -l 24G /swapfile && sudo chmod 600 /swapfile && " \
             "sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile && " \
             "(grep -qF /swapfile /etc/fstab || " \
             "echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab); }"
  ssh(swap_cmd, quiet: true) || abort("!! could not set up the swapfile in the VM")
end

namespace :dev do
  desc "Boot the VM, build the engine if needed, serve the demo at http://localhost:#{HOST_PORT}"
  task :up do
    puts "==> Starting the VM"
    abort("!! vagrant up failed") unless system("vagrant", "up", "--provider=libvirt")

    ensure_disk_size

    puts "==> Ensuring the firefox-wasm sources and engine build"
    build_engine unless engine_built?

    puts "==> Ensuring the demo server (vite) is running in the VM"
    start_demo_server unless demo_serving?
    abort("!! demo server did not come up; see #{VM_REPO}/demo/embed/demo.log in the VM") \
      unless wait_for_demo

    if tunnel_running?
      puts "==> Reusing the running ssh tunnel 127.0.0.1:#{HOST_PORT} -> VM:#{GUEST_PORT}"
    else
      puts "==> Starting the ssh tunnel 127.0.0.1:#{HOST_PORT} -> VM:#{GUEST_PORT}"
      start_tunnel
    end

    if wait_for_http("http://127.0.0.1:#{HOST_PORT}/")
      puts
      puts "==> Ready! Open http://localhost:#{HOST_PORT} in your browser."
      puts "    (first page load downloads the ~240 MB gecko.wasm -- give it a moment)"
    else
      abort("!! tunnel up but no HTTP response on http://localhost:#{HOST_PORT} -- see #{TUNNEL_LOG}")
    end
  end

  desc "Recompile the engine + gecko.js bundle incrementally (no clean)"
  task :compile do
    sync_sources
    puts "==> Recompiling incrementally (make web; no clean)..."
    ssh!(BUILD_CMD)
    puts
    puts "==> Done. Reload the browser tab -- vite serves the fresh gecko.wasm (no-store)."
  end

  desc "Stop the ssh tunnel, the demo server, and the VM"
  task :down do
    puts "==> Stopping the ssh tunnel"
    system("pkill", "-f", "#{HOST_PORT}:localhost:#{GUEST_PORT}", %i[out err] => File::NULL)

    puts "==> Stopping the demo server in the VM"
    ssh("fuser -k #{GUEST_PORT}/tcp 2>/dev/null || true", quiet: true)

    puts "==> Halting the VM"
    abort("!! vagrant halt failed") unless system("vagrant", "halt")

    puts "==> Down. Run `rake dev:up` to start again."
  end

  desc "Delete the whole development environment (VM + engine build inside it)"
  task :destroy do
    puts "==> Stopping the ssh tunnel"
    system("pkill", "-f", "#{HOST_PORT}:localhost:#{GUEST_PORT}", %i[out err] => File::NULL)

    puts "==> Destroying the VM (this deletes the engine build inside it)"
    abort("!! vagrant destroy failed") unless system("vagrant", "destroy", "-f")

    puts "==> Destroyed. Run `rake dev:up` to recreate from scratch (~45 min first build)."
  end
end

task default: "dev:up"
