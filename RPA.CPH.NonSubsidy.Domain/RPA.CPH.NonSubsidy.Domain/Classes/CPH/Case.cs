using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Classes.CPH
{
    [Table("Cases", Schema ="CPH")]
    public class Case
    {
       [Key, ForeignKey("Customer")]
        public int CustomerId { get; set; }

        [Display(Name = "CRM Case Reference")]
        [Required(ErrorMessage = "CRM Reference must be provided.")]
        public string CRMCaseReferenceNumber { get; set; }

        public virtual Customer Customer { get; set; }
    }
}
