class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.0/swiftpods-0.2.0-macos-13.0-arm64.zip"
    sha256 "9b2e22320872ec5001d9044279ad6c7f7eecccc137cfcf2a3261f6dbf11268a1"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.0/swiftpods-0.2.0-macos-13.0-x86_64.zip"
    sha256 "42f9820210bfc9adcfd404af738a204944ec8720688a41a49ef8de4072b8233b"
  end
  version "0.2.0"
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
