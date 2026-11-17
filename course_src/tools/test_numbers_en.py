# -*- coding: utf-8 -*-
"""numbers_en.py: readings of numbers, prices, times, ordinals, phone numbers (K1-4)."""
import unittest

import tool_support  # noqa: F401  (puts the tools folder on sys.path)
import numbers_en as ne

UNITS = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS_WORD = {2: "twenty", 3: "thirty", 4: "forty", 5: "fifty", 6: "sixty", 7: "seventy", 8: "eighty", 9: "ninety"}


def reference(n):
    """Independent implementation (different decomposition) for 0..9999."""
    if n < 20:
        return UNITS[n]
    if n < 100:
        return TENS_WORD[n // 10] if n % 10 == 0 else TENS_WORD[n // 10] + "-" + UNITS[n % 10]
    if n < 1000:
        head = UNITS[n // 100] + " hundred"
        return head if n % 100 == 0 else head + " " + reference(n % 100)
    head = UNITS[n // 1000] + " thousand"
    return head if n % 1000 == 0 else head + " " + reference(n % 1000)


HAND = {0: "zero", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten",
        11: "eleven", 12: "twelve", 13: "thirteen", 14: "fourteen", 15: "fifteen", 16: "sixteen", 17: "seventeen", 18: "eighteen",
        19: "nineteen", 20: "twenty", 21: "twenty-one", 22: "twenty-two", 30: "thirty", 33: "thirty-three", 40: "forty",
        44: "forty-four", 50: "fifty", 55: "fifty-five", 60: "sixty", 66: "sixty-six", 70: "seventy", 77: "seventy-seven",
        80: "eighty", 88: "eighty-eight", 90: "ninety", 99: "ninety-nine", 100: "one hundred", 101: "one hundred one",
        110: "one hundred ten", 111: "one hundred eleven", 120: "one hundred twenty", 199: "one hundred ninety-nine",
        200: "two hundred", 205: "two hundred five", 250: "two hundred fifty", 300: "three hundred", 365: "three hundred sixty-five",
        400: "four hundred", 500: "five hundred", 512: "five hundred twelve", 600: "six hundred", 700: "seven hundred",
        747: "seven hundred forty-seven", 800: "eight hundred", 900: "nine hundred", 999: "nine hundred ninety-nine",
        1000: "one thousand", 1001: "one thousand one", 1010: "one thousand ten", 1100: "one thousand one hundred",
        1234: "one thousand two hundred thirty-four", 1999: "one thousand nine hundred ninety-nine", 2000: "two thousand",
        2024: "two thousand twenty-four", 2500: "two thousand five hundred", 3000: "three thousand",
        4321: "four thousand three hundred twenty-one", 5000: "five thousand", 5050: "five thousand fifty",
        6789: "six thousand seven hundred eighty-nine", 7000: "seven thousand", 8008: "eight thousand eight", 9000: "nine thousand",
        9999: "nine thousand nine hundred ninety-nine", 10000: "ten thousand", 12345: "twelve thousand three hundred forty-five",
        100000: "one hundred thousand", 1000000: "one million",
        1234567: "one million two hundred thirty-four thousand five hundred sixty-seven", 1000000000: "one billion",
        999999999999: "nine hundred ninety-nine billion nine hundred ninety-nine million nine hundred ninety-nine thousand nine hundred ninety-nine"}
HAND.update({23: "twenty-three", 34: "thirty-four", 45: "forty-five", 56: "fifty-six", 67: "sixty-seven", 78: "seventy-eight",
             89: "eighty-nine", 98: "ninety-eight", 102: "one hundred two", 130: "one hundred thirty", 150: "one hundred fifty",
             211: "two hundred eleven", 319: "three hundred nineteen", 420: "four hundred twenty", 678: "six hundred seventy-eight",
             810: "eight hundred ten", 1500: "one thousand five hundred", 1776: "one thousand seven hundred seventy-six",
             3333: "three thousand three hundred thirty-three", 9090: "nine thousand ninety"})


class WordsTest(unittest.TestCase):
    def test_hand_table(self):
        self.assertGreaterEqual(len(HAND), 100)
        for n, want in HAND.items():
            with self.subTest(n=n):
                self.assertEqual(ne.words(n), want)

    def test_all_0_to_9999_against_reference(self):
        for n in range(10000):
            self.assertEqual(ne.words(n), reference(n), n)

    def test_string_input_with_commas(self):
        self.assertEqual(ne.words("1,234"), "one thousand two hundred thirty-four")
        self.assertEqual(ne.words("1,000,000"), "one million")
        self.assertEqual(ne.words("0042"), "forty-two")

    def test_bad_input_returns_none_not_an_exception(self):
        for bad in ("", "abc", -1, -5, "-5", "1.5", 1.5, None, True, [], "1,23", "12,34,56", 10 ** 12, " "):
            with self.subTest(bad=bad):
                self.assertIsNone(ne.words(bad))


class PriceTimeTest(unittest.TestCase):
    def test_price_table(self):
        table = {"5.99": "five ninety-nine", "$5.99": "five ninety-nine", "$20": "twenty dollars", "20": "twenty dollars",
                 "$1": "one dollar", "$1.00": "one dollar", "$0.99": "ninety-nine cents", "$0.01": "one cent",
                 "$1.50": "one fifty", "$5.05": "five oh five", "$12.30": "twelve thirty", "$100": "one hundred dollars",
                 "$1,200": "one thousand two hundred dollars", "$250.75": "two hundred fifty dollars and seventy-five cents",
                 "$3.00": "three dollars", "$19.99": "nineteen ninety-nine"}
        for text, want in table.items():
            with self.subTest(text=text):
                self.assertEqual(ne.price_say(text), want)

    def test_price_alternatives_include_long_form(self):
        self.assertIn("five dollars and ninety-nine cents", ne.price_readings("$5.99"))

    def test_time_table(self):
        table = {"12:30": "twelve thirty", "9:05": "nine oh five", "9:00": "nine o'clock", "12:00": "twelve o'clock",
                 "1:15": "one fifteen", "10:45": "ten forty-five", "9:30 am": "nine thirty a m", "9:30 a.m.": "nine thirty a m",
                 "6:00 PM": "six o'clock p m", "13:20": "thirteen twenty", "0:30": "zero thirty", "11:59": "eleven fifty-nine"}
        for text, want in table.items():
            with self.subTest(text=text):
                self.assertEqual(ne.time_say(text), want)

    def test_bad_price_and_time_return_none(self):
        for bad in ("", "abc", "-5", "$-5", "1.2.3", "$5.9", "5,99", "$", "5.999", None, 5):
            self.assertIsNone(ne.price_say(bad), bad)
        for bad in ("", "abc", "25:00", "13:61", "9:5", "0:00 pm", "13:00 pm", "1:2:3", None, "9.30"):
            self.assertIsNone(ne.time_say(bad), bad)


class OrdinalPhoneTest(unittest.TestCase):
    def test_ordinals(self):
        table = {1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", 8: "eighth", 9: "ninth", 11: "eleventh", 12: "twelfth",
                 13: "thirteenth", 20: "twentieth", 21: "twenty-first", 22: "twenty-second", 30: "thirtieth", 31: "thirty-first",
                 40: "fortieth", 99: "ninety-ninth", 100: "one hundredth", 101: "one hundred first", 1000: "one thousandth",
                 "3rd": "third", "21st": "twenty-first", "1st": "first", "12th": "twelfth", "22nd": "twenty-second"}
        for n, want in table.items():
            with self.subTest(n=n):
                self.assertEqual(ne.ordinal_say(n), want)

    def test_bad_ordinals(self):
        for bad in ("", "abc", -1, "21th", "1th", "3st", None, 1.5, "st"):
            self.assertIsNone(ne.ordinal_say(bad), bad)

    def test_digits_and_phone(self):
        self.assertEqual(ne.digits_say("0123"), "zero one two three")
        self.assertEqual(ne.phone_say("555-0123"), "five five five, oh one two three")
        self.assertEqual(ne.phone_say("604-555-0123"), "six oh four, five five five, oh one two three")
        for bad in ("", "abc", "12", "555-01234", None, "-5"):
            self.assertIsNone(ne.phone_say(bad), bad)
        self.assertIsNone(ne.digits_say("1a"))

    def test_percent_and_decimal(self):
        self.assertEqual(ne.percent_say("20%"), "twenty percent")
        self.assertEqual(ne.percent_say("7.5%"), "seven point five percent")
        self.assertEqual(ne.decimal_say("3.5"), "three point five")
        self.assertIsNone(ne.percent_say("20"))
        self.assertIsNone(ne.decimal_say("3.5.1"))


class SentenceTest(unittest.TestCase):
    def test_say_sentence(self):
        self.assertEqual(ne.say_sentence("It is 2:30 p.m. on May 1st, $5.99."), "It is two thirty p m on May first, five ninety-nine.")
        self.assertEqual(ne.say_sentence("Room 205"), "Room two hundred five")
        self.assertEqual(ne.say_sentence("Call 555-0123."), "Call five five five, oh one two three.")

    def test_needs_say(self):
        for yes in ("Room 3", "$5", "12:30", "Mr. Lee", "20% off", "Call me at 5", "ATM", "Tom & Anna", "a.m."):
            self.assertTrue(ne.needs_say(yes), yes)
        for no in ("Hello.", "No.", "No, thanks.", "I'm fine.", "OK", "It is one.", "", None):
            self.assertFalse(ne.needs_say(no), no)

    def test_say_matches_accepts_and_rejects(self):
        yes = [("My number is 3.", "My number is three."), ("My number is 3.", "my number is THREE"), ("Room 205", "Room two oh five"),
               ("Room 205", "room two zero five"), ("$5.99", "Five ninety-nine"), ("$5.99", "five dollars and ninety-nine cents"),
               ("9:30 a.m.", "nine thirty a m"), ("Mr. Lee", "mister Lee"), ("Meet at 12:30 on 1st", "meet at twelve thirty on first"),
               ("ATM", "a t m"), ("Use the ATM, please", "use the cash machine please")]
        no = [("My number is 3.", "My number is four."), ("My number is 3.", "My number is 3."), ("My number is 3.", "My number is."),
              ("$5.99", "five ninety"), ("$5.99", "five ninety-nine dollars"), ("12:30", "twelve oh thirty"), ("Room 205", "room two hundred"),
              ("Hello.", "Hi.")]
        for text, say in yes:
            with self.subTest(text=text, say=say):
                self.assertTrue(ne.say_matches(text, say))
        for text, say in no:
            with self.subTest(text=text, say=say):
                self.assertFalse(ne.say_matches(text, say))

    def test_four_digit_numbers_also_read_like_years(self):
        self.assertTrue(ne.say_matches("In 1999", "in nineteen ninety-nine"))
        self.assertTrue(ne.say_matches("In 2024", "in twenty twenty-four"))
        self.assertTrue(ne.say_matches("In 1999", "in one thousand nine hundred ninety-nine"))
        self.assertFalse(ne.say_matches("In 1999", "in nineteen ninety"))

    def test_readings_of_one_token(self):
        self.assertEqual(ne.readings("$5.99")[0], "five ninety-nine")
        self.assertEqual(ne.readings("21st"), ["twenty-first"])
        self.assertEqual(ne.readings("2000")[0], "two thousand")
        self.assertIsNone(ne.readings("abc"))


if __name__ == "__main__":
    unittest.main()
