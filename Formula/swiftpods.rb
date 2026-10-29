class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.2/swiftpods-0.2.2-macos-13.0-arm64.zip"
    sha256 "7d0614872d235377dfbf413beeff71e4c0683c1f3751f79a642926bb2c8afc1f"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.2/swiftpods-0.2.2-macos-13.0-x86_64.zip"
    sha256 "725369c7aac6c1c03e0d1d69591fa672e43de1a591040a0d45b2e9d0cfa22c65"
  end
  version "0.2.2"
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
