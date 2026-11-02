class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.9/swiftpods-0.3.9-macos-13.0-arm64.zip"
    sha256 "6755b8b79c3da2a80e5e89ee6db0cbafa537dccbb9b758ce4dbabaa9664615cc"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.9/swiftpods-0.3.9-macos-13.0-x86_64.zip"
    sha256 "d6b39baa3b538289f754bc03e8405aafec8f54f1b5ff14622432595321f593f7"
  end
  version "0.3.9"
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
