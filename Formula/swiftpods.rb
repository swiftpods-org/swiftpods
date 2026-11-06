class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.13/swiftpods-0.3.13-macos-13.0-arm64.zip"
    sha256 "83f929d7541c3e24e3aa0ccea1af82d6efc9ad0d7456c46838df9cef0a4c4c6f"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.13/swiftpods-0.3.13-macos-13.0-x86_64.zip"
    sha256 "fe07576510e0374a341c1ea2ba9ff0c61361dabfc64d2fca37e6fbea233adf1c"
  end
  version "0.3.13"
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
