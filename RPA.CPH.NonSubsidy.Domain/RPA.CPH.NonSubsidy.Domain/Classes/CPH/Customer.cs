using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.CPH
{
    [Table("Customers", Schema = "CPH")]
    public class Customer
    {
        [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
        public int CustomerId { get; set; }

        [Required(ErrorMessage ="SBI is required.")]
        [Range(105000000, 300000000, ErrorMessage ="Invalid SBI.")]
        public int SBI { get; set; }        

        [Display(Name ="Business Name")]
        [Required(ErrorMessage = "Business Name is required.")]
        public string BusinessName { get; set; }
                
        public virtual List<Address> Addresses { get; set; }

        public virtual List<Land> Land { get; set; }        

        public virtual Case Case { get; set; }

        public virtual Audit.Audit Audit { get; set; }

        public Customer() { }

        public Customer(Address address, Land land, Case _case, Audit.Audit audit):this()
        {
            Addresses = new List<Address>
            {
                address
            };

            Land = new List<CPH.Land>
            {
                land
            };

            Case = _case;

            Audit = audit;
        }
    }
}
