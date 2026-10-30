class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.0/swiftpods-0.3.0-macos-13.0-arm64.zip"
    sha256 "a102e360c15f6c384b4ec951a5a2e8966aecfeb8aae2e7bf49d592d4e0eecc8a"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.0/swiftpods-0.3.0-macos-13.0-x86_64.zip"
    sha256 "f1eba2c007f52e7c688042f66f2bd8bdf0aefa9271fba2aba3566f615d6a064b"
  end
  version "0.3.0"
  license "MIT"

  depends_on :macos

  def install
    minimum = { "arm64" => "13.0", "x86_64" => "13.0" }
    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"
    odie "No release for this architecture" unless minimum.key?(architecture)
    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)
    bin.install "bin/swiftpods"
    prefix.install "LICENSE", "README.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/swiftpods version").strip
  end
end
