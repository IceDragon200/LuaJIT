local test = require("test.ljtest")
local datetime = require("datetime")

test.describe("datetime module", function()
  test.it("builds date, time, and naive values with named fields", function(t)
    local date = assert(datetime.date(2024, 2, 29))
    local time = datetime.time(23, 59, 58, 42)
    local naive = assert(datetime.naive(2024, 2, 29, 23, 59, 58, 42))

    t.deep_equal(date, { year = 2024, month = 2, day = 29 })
    t.deep_equal(time, { hour = 23, minute = 59, second = 58, microsecond = 42 })
    t.deep_equal(naive, {
      year = 2024, month = 2, day = 29,
      hour = 23, minute = 59, second = 58, microsecond = 42,
    })
    t.results(t.pack(nil, "invalid date"), function()
      return datetime.date(2023, 2, 29)
    end)
  end)

  test.it("uses proleptic Gregorian calendar arithmetic", function(t)
    t.assert(datetime.is_leap_year(2000))
    t.refute(datetime.is_leap_year(1900))
    t.assert(datetime.is_leap_year(2024))
    t.equal(datetime.day_of_week(assert(datetime.date(1970, 1, 1))), 4)
    t.deep_equal(assert(datetime.date_add(assert(datetime.date(2024, 2, 28)), 1)),
      { year = 2024, month = 2, day = 29 })
    t.equal(datetime.date_diff(assert(datetime.date(2025, 1, 1)),
      assert(datetime.date(2024, 1, 1))), 366)
  end)

  test.it("round-trips Unix seconds and microseconds through UTC", function(t)
    local epoch = assert(datetime.from_unix(0))
    local before_epoch = assert(datetime.from_unix(-1, 999999))
    local precise = assert(datetime.from_unix(1, 500000))

    t.equal(datetime.to_iso8601(epoch), "1970-01-01T00:00:00Z")
    t.equal(datetime.to_iso8601(before_epoch), "1969-12-31T23:59:59.999999Z")
    t.results(t.pack(1, 500000), function() return datetime.to_unix(precise) end)
    t.equal(datetime.to_iso8601(assert(datetime.add(epoch, 86400))),
      "1970-01-02T00:00:00Z")
    t.results(t.pack(1, 500000), function()
      return datetime.diff(precise, assert(datetime.from_unix(0, 0)))
    end)
    t.equal(datetime.compare(epoch, precise), -1)
  end)

  test.it("parses and formats strict UTC ISO 8601 values", function(t)
    local parsed = assert(datetime.from_iso8601("2026-07-23T14:30:00.25Z"))

    t.equal(datetime.to_iso8601(parsed), "2026-07-23T14:30:00.250000Z")
    t.deep_equal({ parsed.time_zone, parsed.zone_abbr, parsed.utc_offset,
      parsed.std_offset }, { "Etc/UTC", "UTC", 0, 0 })
    t.results(t.pack(nil, "invalid UTC ISO 8601 datetime"), function()
      return datetime.from_iso8601("2026-07-23T14:30:00+05:30")
    end)
  end)

  test.it("makes the future timezone seam explicit instead of guessing", function(t)
    local naive = assert(datetime.naive(2026, 7, 23, 14, 30, 0))
    local utc = assert(datetime.from_naive(naive))

    t.equal(utc.time_zone, "Etc/UTC")
    t.results(t.pack(nil, "time zone database unavailable"), function()
      return datetime.from_naive(naive, "America/New_York")
    end)
    t.results(t.pack(nil, "time zone database unavailable"), function()
      return datetime.shift_zone(utc, "Europe/Paris")
    end)
  end)

  test.it("reads a microsecond-resolution UTC wall clock", function(t)
    local now = datetime.utc_now()

    t.equal(now.time_zone, "Etc/UTC")
    t.in_range(now.microsecond, 0, 999999)
    t.matches(now, { year = now.year, month = now.month, day = now.day,
      hour = now.hour, minute = now.minute, second = now.second })
  end)
end)
