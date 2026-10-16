using System.ComponentModel.DataAnnotations;
using NUnit.Framework;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;

namespace RPA.CPH.NonSubsidy.Domain.Tests
{
    [TestFixture]
    public class DomainModelTests
    {
        [Test]
        public void Land_Cph_IsFormattedWithLeadingZeros()
        {
            var land = new Land { County = 1, Parish = 23, Holding = 456 };

            Assert.That(land.CPH, Is.EqualTo("01/023/0456"));
        }

        [Test]
        public void Address_FullAddress_SkipsEmptyLines()
        {
            var address = new Address { Address1 = "1 High Street", Address4 = "Leeds", PostCode = "LS1 1AA" };

            Assert.That(address.FullAddress, Is.EqualTo("1 High Street, Leeds, LS1 1AA"));
        }

        [Test]
        public void Land_PlaceOfBusinessReference_UsesActivePlaceOfBusinessParcel()
        {
            var land = new Land();
            land.LandParcels.Add(new LandParcel { GridReference = "SK12345678", PlaceOfBusiness = true });
            land.LandParcels.Add(new LandParcel { GridReference = "SK87654321", PlaceOfBusiness = true, Active = false });

            Assert.That(land.PlaceOfBusinessReference, Is.EqualTo("SK12345678"));
        }

        [TestCase("SK12345678", true)]
        [TestCase("SK1234", false)]
        public void LandParcel_GridReference_IsValidated(string gridReference, bool expectedValid)
        {
            var parcel = new LandParcel(1) { LandParcelId = 1, GridReference = gridReference };
            var results = new List<ValidationResult>();

            var valid = Validator.TryValidateObject(parcel, new ValidationContext(parcel), results, true);

            Assert.That(valid, Is.EqualTo(expectedValid));
        }

        [TestCase("LS1 1AA", true)]
        [TestCase("NOTAPOSTCODE", false)]
        public void Address_PostCode_IsValidated(string postCode, bool expectedValid)
        {
            var address = new Address { Address1 = "1 High Street", PostCode = postCode };
            var results = new List<ValidationResult>();

            var valid = Validator.TryValidateObject(address, new ValidationContext(address), results, true);

            Assert.That(valid, Is.EqualTo(expectedValid));
        }
    }
}
