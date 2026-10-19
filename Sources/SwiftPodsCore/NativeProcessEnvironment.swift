enum NativeProcessEnvironment {
    static func isValidName(_ value: String) -> Bool {
        !value.isEmpty && !value.utf8.contains(where: { $0 == 0 || $0 == 61 })
    }
}
