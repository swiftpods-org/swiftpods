class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.3/swiftpods-0.2.3-macos-13.0-arm64.zip"
    sha256 "740bc89e10f6c20f274131c204e31e91d500d18cac95cca94b014465687c29e8"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.3/swiftpods-0.2.3-macos-13.0-x86_64.zip"
    sha256 "e3ca56c00a880c8637d0ef65a3e9187df624b0ac82f5ceabcdd4d7d943a46187"
  end
  version "0.2.3"
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
