package com.qadinet.cardbot

/** تطبيع الرقم إلى صيغة دولية قبل فتح محرر SMS، دون إرسال الرسالة. */
object PhoneNumberNormalizer {
    fun toSmsAddress(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val digits = buildString {
            trimmed.forEach { char ->
                when (char) {
                    in '٠'..'٩' -> append('0' + (char - '٠'))
                    in '۰'..'۹' -> append('0' + (char - '۰'))
                    in '0'..'9' -> append(char)
                }
            }
        }
        if (digits.isEmpty()) return null

        val hasInternationalPrefix = trimmed.startsWith('+') || digits.startsWith("00")
        val international = when {
            digits.startsWith("00") -> digits.drop(2)
            trimmed.startsWith('+') -> digits
            digits.startsWith("967") -> digits
            digits.length == 9 && digits.startsWith('7') -> "967$digits"
            digits.length == 10 && digits.startsWith("07") -> "967${digits.drop(1)}"
            else -> return null
        }
        if (international.length !in 8..15 || international.startsWith('0')) return null
        if (international.startsWith("967") &&
            (international.length != 12 || !international.substring(3).startsWith('7'))
        ) return null
        if (!hasInternationalPrefix && !international.startsWith("967")) return null
        return "+$international"
    }
}
