using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.CPH
{
    [Table("Land", Schema = "CPH")]
    public class Land
    {
        [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
        public int LandId { get; set; }

        public int CustomerId { get; set; }

        [Required(ErrorMessage = "County is required.")]
        [Range(1, 99, ErrorMessage = "Invalid County.")]
        [DisplayFormat(ApplyFormatInEditMode = true, ConvertEmptyStringToNull = true, DataFormatString = "{0:D2}")]
        public int County { get; set; }
        
        [Required(ErrorMessage = "Parish is required.")]
        [Range(1, 999, ErrorMessage = "Invalid Parish.")]
        [DisplayFormat(ApplyFormatInEditMode = true, ConvertEmptyStringToNull = true, DataFormatString = "{0:D3}")]
        public int Parish { get; set; }

        [Required(ErrorMessage = "Holding is required.")]
        [Range(1, 9999, ErrorMessage = "Invalid Holding.")]
        [DisplayFormat(ApplyFormatInEditMode = true, ConvertEmptyStringToNull = true, DataFormatString = "{0:D4}")]
        public int Holding { get; set; }

        public virtual List<LandParcel> LandParcels { get; set; }

        public virtual Customer Customer { get; set; }
        
        public string CPH
        {
            get
            {
                return string.Format("{0:D2}/{1:D3}/{2:D4}", County, Parish, Holding);
            }
        }

        public string PlaceOfBusinessReference
        {
            get
            {
                return LandParcels.Where(x => x.IsPlaceOfBusiness && x.Active).Select(x => x.GridReference).FirstOrDefault();
            }
        }

        [Display(Name = "Land Parcels")]
        public string LandParcelDetails
        {
            get
            {
                StringBuilder sb = new StringBuilder();

                var activeLandParcels = LandParcels.Where(x => x.Active).ToList();

                int i = 0;

                foreach (LandParcel landParcel in activeLandParcels)
                {
                    sb.Append(landParcel.GridReference);

                    i++;

                    if (i < activeLandParcels.Count())
                    {
                        sb.Append(", ");
                    }
                }

                return sb.ToString();
            }
        }

        public Land()
        {
            LandParcels = new List<LandParcel>();
        }
    }
}
