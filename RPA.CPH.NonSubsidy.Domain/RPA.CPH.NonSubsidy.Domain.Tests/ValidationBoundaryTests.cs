using System.ComponentModel.DataAnnotations;
using System.Globalization;
using NUnit.Framework;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;

namespace RPA.CPH.NonSubsidy.Domain.Tests;

[TestFixture]
[Category("Unit")]
public class ValidationBoundaryTests
{
    private static string[] Errors(object model, string property, object value)
    {
        var results = new List<ValidationResult>();
        Validator.TryValidateProperty(value, new ValidationContext(model) { MemberName = property }, results);
        return results.Select(x => x.ErrorMessage).ToArray();
    }

    [TestCase(null)]
    [TestCase("")]
    [TestCase(" \t")]
    public void RequiredStrings_PreserveExactMessages(string value)
    {
        Assert.That(Errors(new Customer(), "BusinessName", value), Is.EqualTo(new[] { "Business Name is required." }));
        Assert.That(Errors(new Address(), "Address1", value), Is.EqualTo(new[] { "First line of Address is required." }));
        Assert.That(Errors(new Case(), "CRMCaseReferenceNumber", value), Is.EqualTo(new[] { "CRM Reference must be provided." }));
        var postcode = Errors(new Address(), "PostCode", value);
        Assert.That(postcode, Does.Contain("Post Code is required."));
        Assert.That(postcode, Is.EqualTo(new[] { "Post Code is required." }));
        var custom = new RPA.CPH.NonSubsidy.Domain.Attributes.PostCode();
        Assert.That(custom.GetValidationResult(value, new ValidationContext(new Address()))?.ErrorMessage,
            Is.EqualTo(value == null ? null : "Invalid Post Code."));
    }

    [TestCase("County", 99)]
    [TestCase("Parish", 999)]
    [TestCase("Holding", 9999)]
    public void LandRanges_IncludeBothEndpointsAndRejectAdjacentValues(string property, int maximum)
    {
        var land = new Land();
        foreach (var value in new[] { 1, maximum })
            Assert.That(Errors(land, property, value), Is.Empty);
        foreach (var value in new[] { -1, 0, maximum + 1 })
            Assert.That(Errors(land, property, value), Is.EqualTo(new[] { $"Invalid {property}." }));
    }

    [TestCase(105000000, true)]
    [TestCase(300000000, true)]
    [TestCase(104999999, false)]
    [TestCase(300000001, false)]
    [TestCase(0, false)]
    public void SbiRange_PreservesInclusiveBounds(int value, bool valid)
    {
        Assert.That(Errors(new Customer(), "SBI", value),
            Is.EqualTo(valid ? Array.Empty<string>() : new[] { "Invalid SBI." }));
        Assert.That(Errors(new Customer(), "BusinessName", new string('x', 5000)), Is.Empty);
    }

    [TestCase("ls1 1aa", true)]
    [TestCase("GIR 0AA", true)]
    [TestCase("GIR 0AAtrailing", true)]
    [TestCase("prefixLS1 1AA", true)]
    [TestCase("LS1 1AA ", false)]
    [TestCase("LS11AA", false)]
    [TestCase("LS1  1AA", false)]
    public void PostcodeRegex_PreservesCaseAndAlternationQuirks(string value, bool valid) =>
        Assert.That(Errors(new Address(), "PostCode", value),
            Is.EqualTo(valid ? Array.Empty<string>() : new[] { "Invalid Post Code." }));

    [TestCase("sk12345678", 1, true, true)]
    [TestCase("[_12345678", 1, true, true)]
    [TestCase("SK12345678\n", 1, true, true)]
    [TestCase(" SK12345678", 1, true, false)]
    [TestCase(null, 0, true, true)]
    [TestCase(null, 1, true, false)]
    [TestCase("", 0, true, false)]
    [TestCase("bad", 1, false, true)]
    public void GridRegex_PreservesBypassesPunctuationAndAnchoring(string value, int id, bool active, bool valid)
    {
        var parcel = new LandParcel { LandParcelId = id, Active = active };
        Assert.That(Errors(parcel, "GridReference", value),
            Is.EqualTo(valid ? Array.Empty<string>() : new[] { "Invalid Grid Reference." }));
    }

    [Test]
    public void ComputedDisplays_PreserveEmptyWhitespaceOrderAndTwelveHourClock()
    {
        Assert.That(new Address().FullAddress, Is.EqualTo(", "));
        var address = new Address { Address1 = "A", Address2 = "", Address3 = " ", Address4 = "B", Address5 = "C", PostCode = "D" };
        Assert.That(address.FullAddress, Is.EqualTo("A,  , B, C, D"));
        var land = new Land { County = 99, Parish = 999, Holding = 9999 };
        Assert.That(land.CPH, Is.EqualTo("99/999/9999"));
        Assert.That(new Land().CPH, Is.EqualTo("00/000/0000"));
        Assert.That(land.LandParcelDetails, Is.Empty);
        Assert.That(land.PlaceOfBusinessReference, Is.Null);
        land.LandParcels =
        [
            new() { GridReference = "inactive", Active = false, PlaceOfBusiness = true },
            new() { GridReference = "second", PlaceOfBusiness = true },
            new() { GridReference = "first", PlaceOfBusiness = true }
        ];
        Assert.That(land.LandParcelDetails, Is.EqualTo("second, first"));
        Assert.That(land.PlaceOfBusinessReference, Is.EqualTo("second"));
        land.LandParcels[1].PlaceOfBusiness = false;
        Assert.That(land.LandParcels[1].IsPlaceOfBusiness, Is.False);
        Assert.That(land.PlaceOfBusinessReference, Is.EqualTo("first"));
        using var culture = new CultureScope("en-GB");
        Assert.That(new Audit { LastUpdatedBy = "actor", LastUpdated = new DateTime(2026, 12, 31, 23, 59, 0) }.LastUpdatedDetails,
            Is.EqualTo("Last updated by actor on 31/12/2026 11:59"));
        foreach (var hour in new[] { 0, 12 })
            Assert.That(new Audit { LastUpdatedBy = "actor", LastUpdated = new DateTime(2027, 1, 1, hour, 0, 0) }.LastUpdatedDetails,
                Is.EqualTo("Last updated by actor on 01/01/2027 12:00"));
    }

    private sealed class CultureScope(string name) : IDisposable
    {
        private readonly CultureInfo previous = CultureInfo.CurrentCulture;
        private readonly CultureInfo current = CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(name);
        public void Dispose() => CultureInfo.CurrentCulture = previous;
    }
}
