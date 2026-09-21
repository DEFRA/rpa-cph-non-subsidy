using RPA.CPH.NonSubsidy.Domain.Attributes;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.CPH
{
    [Table("LandParcels", Schema ="CPH")]
    public class LandParcel : IFormatCSV
    {
        [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
        public int LandParcelId { get; set; }
        
        public int LandId { get; set; }

        [Display(Name = "Grid Reference")]
        [GridReference(ErrorMessage = "Invalid Grid Reference")]
        public string GridReference { get; set; }

        [Display(Name = "POB")]
        public bool PlaceOfBusiness { get; set; }

        public bool Active { get; set; }

        public bool IsPlaceOfBusiness
        {
            get
            {
                if (PlaceOfBusiness)
                {
                    return true;
                }
                else
                {
                    return false;
                }
            }
        }

        public virtual Land Land { get; set; }

        public LandParcel()
        {
            PlaceOfBusiness = false;
            Active = true;
        }

        public LandParcel(int landId):this()
        {
            LandId = landId;
        }

        public string ToCSV()
        {
            return string.Format("\"{0}\",\"{1}\",\"{2}\",\"{3}\",\"{4}\",\"{5}\",\"{6}\",\"{7}\",\"{8}\"",
                Land.Customer.SBI,
                Land.Customer.BusinessName,
                Land.Customer.Addresses.FirstOrDefault().FullAddress,
                Land.CPH,
                Land.PlaceOfBusinessReference,
                GridReference,
                Land.Customer.Case.CRMCaseReferenceNumber,
                Land.Customer.Audit.LastUpdatedBy,
                Land.Customer.Audit.LastUpdated
                );
        }
    }
}
