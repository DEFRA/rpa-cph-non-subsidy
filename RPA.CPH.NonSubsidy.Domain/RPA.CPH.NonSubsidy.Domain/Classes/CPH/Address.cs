using RPA.CPH.NonSubsidy.Domain.Attributes;
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.CPH
{
    [Table("Addresses", Schema = "CPH")]
    public class Address
    {
        [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
        public int AddressId { get; set; }
        
        public int CustomerId { get; set; }

        [Required(ErrorMessage ="First line of Address is required.")]
        [Display(Name = "Address 1")]
        public string Address1 { get; set; }

        [Display(Name = "Address 2")]
        public string Address2 { get; set; }

        [Display(Name = "Address 3")]
        public string Address3 { get; set; }

        [Display(Name = "City")]
        public string Address4 { get; set; }

        [Display(Name = "County")]
        public string Address5 { get; set; }

        [PostCode]
        [Required(ErrorMessage = "Post Code is required.")]
        [Display(Name = "Post Code")]
        public string PostCode { get; set; }

        [Display(Name = "Address")]
        public string FullAddress
        {
            get
            {
                StringBuilder sb = new StringBuilder();

                sb.AppendFormat("{0}, ", Address1);

                if(!string.IsNullOrEmpty(Address2))
                {
                    sb.AppendFormat("{0}, ", Address2);
                }

                if (!string.IsNullOrEmpty(Address3))
                {
                    sb.AppendFormat("{0}, ", Address3);
                }

                if (!string.IsNullOrEmpty(Address4))
                {
                    sb.AppendFormat("{0}, ", Address4);
                }

                if (!string.IsNullOrEmpty(Address5))
                {
                    sb.AppendFormat("{0}, ", Address5);
                }

                sb.AppendFormat("{0}", PostCode);

                return sb.ToString();
            }
        }

        public virtual Customer Customer { get; set; }

        public Address() { }        
    }
}
