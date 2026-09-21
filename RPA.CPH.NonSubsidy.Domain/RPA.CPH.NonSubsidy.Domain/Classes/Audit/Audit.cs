using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.Audit
{
    [Table("Audit", Schema = "Audit")]
    public class Audit
    {
        [Key, ForeignKey("Customer")]
        public int CustomerId { get; set; }

        public string LastUpdatedBy { get; set; }

        public DateTime LastUpdated { get; set; }

        public string LastUpdatedDetails
        {
            get
            {
                return string.Format("Last updated by {0} on {1}", LastUpdatedBy, LastUpdated.ToString("dd/MM/yyyy hh:mm"));
            }
        }

        public virtual Customer Customer { get; set; }

        public void Update(string lastUpdatedBy)
        {
            LastUpdatedBy = lastUpdatedBy;
            LastUpdated = DateTime.Now;
        }

    }
}
